package TestServers;
use strict;
use warnings;
use Path::Tiny;
use lib path (__FILE__)->parent->parent->parent->child ('local/accounts/t_deps/lib')->stringify;
use lib path (__FILE__)->parent->parent->parent->child ('local/accounts/t_deps/modules/promised-plackup/lib')->stringify;
use File::Temp;
use JSON::PS;
use Promise;
use Promised::Flow;
use Promised::File;
use Promised::Command;
use Promised::Command::Signals;
use Promised::Mysqld;
use Web::Encoding;
use Web::URL;
use Web::Transport::ConnectionClient;
use Sarze;

my $RootPath = path (__FILE__)->parent->parent->parent->absolute;

{
  use Socket;
  my $EphemeralStart = 1024;
  my $EphemeralEnd = 5000;

  sub is_listenable_port ($) {
    my $port = $_[0];
    return 0 unless $port;
    
    my $proto = getprotobyname('tcp');
    socket(my $server, PF_INET, SOCK_STREAM, $proto) || die "socket: $!";
    setsockopt($server, SOL_SOCKET, SO_REUSEADDR, pack("l", 1)) || die "setsockopt: $!";
    bind($server, sockaddr_in($port, INADDR_ANY)) || return 0;
    listen($server, SOMAXCONN) || return 0;
    close($server);
    return 1;
  } # is_listenable_port

  my $using = {};
  sub find_listenable_port () {
    for (1..10000) {
      my $port = int rand($EphemeralEnd - $EphemeralStart);
      next if $using->{$port}++;
      return $port if is_listenable_port $port;
    }
    die "Listenable port not found";
  } # find_listenable_port
}

sub mysqld (%) {
  my %args = @_;
  my $db_name = encode_web_utf8 ($args{db_name} // 'test_' . int rand 100000);
  my $mysqld = Promised::Mysqld->new;
  $mysqld->set_db_dir ($args{db_path}) if defined $args{db_path};
  return $mysqld->start->then (sub {
    my $sql_path = $RootPath->child ('db/moktan.sql');
    return Promised::File->new_from_path ($sql_path)->read_byte_string->then (sub {
      return $mysqld->create_db_and_execute_sqls ($db_name, [grep { length } split /;/, $_[0]]);
    });
  })->then (sub {
    my $info = {};
    $info->{dsn} = $mysqld->get_dsn_string (dbname => $db_name);
    $args{send_info}->($info);
    my ($p_ok, $p_ng);
    my $p = Promise->new (sub { ($p_ok, $p_ng) = @_ });
    return [sub {
      return $mysqld->stop->then ($p_ok, $p_ng);
    }, $p];
  });
} # mysqld

sub web (%) {
  my %args = @_;

  my $port = $args{port} || find_listenable_port;

  my $temp = File::Temp->new;
  my $command = Promised::Command->new
      ([$RootPath->child ('perl'), $RootPath->child ('bin/sarze-server.pl'), $port, $temp]);

  my $stop = sub {
    $command->send_signal ('TERM');
    undef $temp;
    return $command->wait;
  }; # $stop

  my ($ready, $failed) = @_;
  my $p = Promise->new (sub { ($ready, $failed) = @_ });

  $args{receive_mysqld_info}->then (sub {
    my $info = $_[0];
    $args{config}->{dsn} = $info->{dsn};
    return Promised::File->new_from_path ($temp)->write_byte_string
        (perl2json_bytes $args{config});
  })->then (sub {
    return $command->run;
  })->then (sub {
    $command->wait->then (sub {
      $failed->($_[0]);
    });
    my $origin = Web::URL->parse_string (qq<http://localhost:$port>);
    return promised_wait_until {
      my $client = Web::Transport::ConnectionClient->new_from_url ($origin);
      return $client->request (path => ['robots.txt'])->then (sub {
        return not $_[0]->is_network_error;
      });
    } timeout => 60*2;
  })->then (sub {
    my $info = {};
    $info->{url} = Web::URL->parse_string ("http://0:$port");
    $args{send_info}->($info);
    $ready->([$stop, $command->wait]);
  }, sub {
    my $error = $_[0];
    return $stop->()->catch (sub {
      warn "ERROR: $_[0]";
    })->then (sub { $failed->($error) });
  });

  return $p;
} # web

sub servers ($%) {
  shift;
  my %args = @_;

  return Promised::File->new_from_path ($args{json_path})->read_byte_string->then (sub {
    my $config = json_bytes2perl $_[0];
    $config->{base_path} //= $args{json_path}->absolute;

    if (defined $config->{db_path}) {
      $args{db_path} = path ($config->{db_path})->absolute ($args{json_path}->parent);
    }

    my ($receive_mysqld_info, $send_mysqld_info) = promised_cv;

    return Promise->all ([
      mysqld (
        db_name => $config->{db_name} // $args{db_name},
        db_path => $args{db_path},
        send_info => $send_mysqld_info,
      ),
      web (
        port => $args{port},
        config => $config,
        receive_mysqld_info => $receive_mysqld_info,
        send_info => $args{send_info},
      ),
    ]);
  })->then (sub {
    my $stops = $_[0];
    my @stopped = grep { defined } map { $_->[1] } @$stops;
    my @signal;

    my $stop = sub {
      my $cancel = $_[0] || sub { };
      $cancel->();
      @signal = ();
      return Promise->all ([map {
        my ($stop) = @$_;
        Promise->resolve->then ($stop)->catch (sub {
          warn "$$: ERROR: $_[0]";
        });
      } grep { defined } @$stops]);
    }; # $stop

    push @signal, Promised::Command::Signals->add_handler (INT => $stop);
    push @signal, Promised::Command::Signals->add_handler (TERM => $stop);
    push @signal, Promised::Command::Signals->add_handler (KILL => $stop);

    return [$stop, sub {
      @signal = ();
      return Promise->all ([map {
        $_->catch (sub {
          warn "$$: ERROR: $_[0]";
        });
      } @stopped]);
    }];
  });
} # servers

1;

=head1 LICENSE

Copyright 2016-2017 Wakaba <wakaba@suikawiki.org>.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Affero General Public License for more details.

You does not have received a copy of the GNU Affero General Public
License along with this program, see <https://www.gnu.org/licenses/>.

=cut
