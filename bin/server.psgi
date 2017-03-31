# -*- Perl -*-
use strict;
use warnings;
use JSON::PS;
use Time::HiRes qw(time);
use Path::Tiny;
use Promised::Flow;
use Promised::File;
use Web::DOM::Document;
use Temma::Parser;
use Temma::Processor;
use Dongry::Database;
use Dongry::Type;
use Dongry::Type::JSONPS;
use Wanage::HTTP;
use Warabe::App;

my $json_path = path ($ENV{APP_JSON_PATH} or die "No |APP_JSON_PATH|")->absolute;
my $Config = json_bytes2perl $json_path->slurp;
for my $key (qw(base html js css)) {
  $Config->{$key.'_path'} = path ($Config->{$key.'_path'} // './' . $key)->absolute (path ($Config->{base_path} // $json_path)->parent);
}
$Config->{js_core_path} = path (__FILE__)->parent->parent->child ('js');
$Config->{css_core_path} = path (__FILE__)->parent->parent->child ('css');

sub with_db (&) {
  my $db = Dongry::Database->new (sources => {
    master => {
      dsn => Dongry::Type->serialize ('text', $Config->{dsn}),
      anyevent => 1,
      writable => 1,
    },
  });
  return promised_cleanup {
    return $db->disconnect;
  } Promise->resolve ($db)->then ($_[0]);
} # with_db

sub static ($$$) {
  my ($app, $type, $path) = @_;
  my $file = Promised::File->new_from_path
      ($Config->{{
        css => 'css_path',
        js => 'js_path',
        css_core => 'css_core_path',
        js_core => 'js_core_path',
      }->{$type}}->child ($path));
  return $file->stat->then (sub {
    return $_[0]->mtime;
  }, sub {
    return $app->throw_error (404, reason_phrase => 'File not found');
  })->then (sub {
    $app->http->set_response_last_modified ($_[0]);
    return $file->read_byte_string->then (sub {
      $app->http->add_response_header ('Content-Type' => {
        css => 'text/css; charset=utf-8',
        css_core => 'text/css; charset=utf-8',
        js => 'text/javascript; charset=utf-8',
        js_core => 'text/javascript; charset=utf-8',
      }->{$type});
      $app->http->send_response_body_as_ref (\($_[0]));
      return $app->http->close_response_body;
    });
  });
} # static

sub json ($$) {
  my ($app) = @_;
  $app->http->set_response_header
      ('Content-Type' => 'application/json; charset=utf-8');
  $app->http->send_response_body_as_ref (\perl2json_bytes $_[1]);
  $app->http->close_response_body;
} # json

{
  sub temma ($$$) {
    my ($app, $template_path, $args) = @_;
    my $http = $app->http;
    my $path = $Config->{html_path}->child ($template_path);
    my $file = Promised::File->new_from_path ($path);
    return $file->is_file->then (sub {
      unless ($_[0]) {
        return $app->throw_error
            (404, reason_phrase => "HTML template |$template_path| not found");
      }
      return $file->read_char_string;
    })->then (sub {
      my $fh = Results::Temma::Printer->new_from_http ($http);
      my $doc = new Web::DOM::Document;
      my $parser = Temma::Parser->new;
      $parser->parse_char_string ($_[0] => $doc);
      my $processor = Temma::Processor->new;
      $processor->oninclude (sub {
        my $x = $_[0];
        my $path = path ($x->{path})->absolute ($Config->{html_path});
        my $parser = $x->{get_parser}->();
        $parser->onerror (sub {
          $x->{onerror}->(@_, path => $path);
        });
        return Promised::File->new_from_path ($path)->read_char_string->then (sub {
          my $doc = Web::DOM::Document->new;
          $parser->parse_char_string ($_[0] => $doc);
          return $doc;
        });
      });
      $http->set_response_header ('Content-Type' => 'text/html; charset=utf-8');
      return Promise->new (sub {
        my $ok = $_[0];
        $processor->process_document ($doc => $fh, ondone => sub {
          undef $fh;
          $http->close_response_body;
          $ok->();
        }, args => {%$args, app => $app});
      });
    });
  } # temma

  package Results::Temma::Printer;

  sub new_from_http ($$) {
    return bless {http => $_[1], value => ''}, $_[0];
  } # new_from_http

  sub print ($$) {
    $_[0]->{value} .= $_[1];
    if (length $_[0]->{value} > 1024*10 or length $_[1] == 0) {
      $_[0]->{http}->send_response_body_as_text ($_[0]->{value});
      $_[0]->{value} = '';
    }
  } # print

  sub DESTROY {
    $_[0]->{http}->send_response_body_as_text ($_[0]->{value})
        if length $_[0]->{value};
  } # DESTROY
}

sub this_page ($%) {
  my ($app, %args) = @_;
  my $page = {
    order_direction => 'DESC',
    limit => 0+($app->bare_param ('limit') // $args{limit} // 30),
    offset => 0,
    value => undef,
  };
  my $max_limit = $args{max_limit} // 100;
  return $app->throw_error (400, reason_phrase => "Bad |limit|")
      if $page->{limit} < 1 or $page->{limit} > $max_limit;
  my $ref = $app->bare_param ('ref');
  if (defined $ref) {
    if ($ref =~ /\A([+-])([0-9.]+),([0-9]+)\z/) {
      $page->{order_direction} = $1 eq '+' ? 'ASC' : 'DESC';
      $page->{exact_value} = 0+$2;
      $page->{value} = {($page->{order_direction} eq 'ASC' ? '>=' : '<='), $page->{exact_value}};
      $page->{offset} = 0+$3;
      return $app->throw_error (400, reason_phrase => "Bad |ref| offset")
          if $page->{offset} > 100;
      $page->{ref} = $ref;
    } else {
      return $app->throw_error (400, reason_phrase => "Bad |ref|");
    }
  }
  return $page;
} # this_page

sub next_page ($$$) {
  my ($this_page, $items, $value_key) = @_;
  my $next_page = {};
  my $sign = $this_page->{order_direction} eq 'ASC' ? '+' : '-';
  my $values = {};
  $values->{$this_page->{exact_value}} = $this_page->{offset}
      if defined $this_page->{exact_value};
  if (ref $items eq 'ARRAY') {
    if (@$items) {
      my $last_value = $items->[0]->{$value_key};
      for (@$items) {
        $values->{$_->{$value_key}}++;
        if ($sign eq '+') {
          $last_value = $_->{$value_key} if $last_value < $_->{$value_key};
        } else {
          $last_value = $_->{$value_key} if $last_value > $_->{$value_key};
        }
      }
      $next_page->{next_ref} = $sign . $last_value . ',' . $values->{$last_value};
      $next_page->{has_next} = @$items == $this_page->{limit};
    } else {
      $next_page->{next_ref} = $this_page->{ref};
      $next_page->{has_next} = 0;
    }
  } else { # HASH
    if (keys %$items) {
      my $last_value = $items->{each %$items}->{$value_key};
      for (values %$items) {
        $values->{$_->{$value_key}}++;
        if ($sign eq '+') {
          $last_value = $_->{$value_key} if $last_value < $_->{$value_key};
        } else {
          $last_value = $_->{$value_key} if $last_value > $_->{$value_key};
        }
      }
      $next_page->{next_ref} = $sign . $last_value . ',' . $values->{$last_value};
      $next_page->{has_next} = (keys %$items) == $this_page->{limit};
    } else {
      $next_page->{next_ref} = $this_page->{ref};
      $next_page->{has_next} = 0;
    }
  }
  return $next_page;
} # next_page

my $NamePattern = qr/[A-Za-z][A-Za-z0-9_]*/;

return sub {
  my $http = Wanage::HTTP->new_from_psgi_env ($_[0]);
  my $app = Warabe::App->new_from_http ($http);
  $app->execute_by_promise (sub {
    warn sprintf "ACCESS: [%s] %s %s FROM %s %s\n",
        scalar gmtime,
        $app->http->request_method, $app->http->url->stringify,
        $app->http->client_ip_addr->as_text,
        $app->http->get_request_header ('User-Agent') // '';

    $app->http->set_response_header
        ('Strict-Transport-Security',
         'max-age=10886400; includeSubDomains; preload');

    my $path = $app->path_segments;

    if ($path->[-1] eq '' and
        not grep { not /\A$NamePattern\z/o } @$path[0..($#$path-1)]) {
      # /{name}/.../{name}/
      my $file = (join '.', @$path) . 'index.html.tm';
      return temma $app, $file, {};
    }

    if (@$path == 3 and
        $path->[0] =~ /\A$NamePattern\z/o and
        $path->[1] =~ /\A[1-9][0-9]*\z/ and
        $path->[2] eq '') {
      # /{name}/{id}/
      return with_db {
        my $db = shift;
        return $db->select ('object', {
          type => Dongry::Type->serialize ('text', $path->[0]),
          id => Dongry::Type->serialize ('text', $path->[1]),
        }, fields => ['id'], source_name => 'master')->then (sub {
          return $app->throw_error (404, reason_phrase => 'Object not found')
              unless $_[0]->first;
          my $file = $path->[0] . '.id.index.html.tm';
          return temma $app, $file, {};
        });
      };
    }

    if (@$path == 3 and
        $path->[0] =~ /\A$NamePattern\z/o and
        $path->[1] =~ /\A[1-9][0-9]*\z/ and
        $path->[2] eq 'info.json') {
      # /{name}/{id}/info.json
      return with_db {
        my $db = shift;
        return $db->select ('object', {
          type => Dongry::Type->serialize ('text', $path->[0]),
          id => Dongry::Type->serialize ('text', $path->[1]),
        }, source_name => 'master')->then (sub {
          my $all = $_[0]->all;
          return $app->throw_error (404, reason_phrase => 'Object not found')
              unless @$all;
          my $items = [map {
            $_->{data} = Dongry::Type->parse ('json', $_->{data});
            $_->{id} .= '';
            $_->{type} = $path->[0];
            $_;
          } @$all];
          return json $app, {objects => $items};
        });
      };
    }

    if (@$path == 2 and
        $path->[0] =~ /\A$NamePattern\z/o and
        $path->[1] eq 'list.json') {
      # /{name}/list.json
      return with_db {
        my $db = shift;
        my $page = this_page ($app, limit => 30, max_limit => 100);
        my $where = {
          type => Dongry::Type->serialize ('text', $path->[0]),
        };
        $where->{timestamp} = $page->{value} if defined $page->{value};
        my $filters = $app->text_param_list ('filter');
        return $db->select ('object', $where,
          source_name => 'master',
          offset => $page->{offset}, limit => $page->{limit} * 5,
          order => ['timestamp', $page->{order_direction}],
        )->then (sub {
          my $items = [map {
            $_->{data} = Dongry::Type->parse ('json', $_->{data});
            $_->{id} .= '';
            $_->{type} = $path->[0];
            $_;
          } @{$_[0]->all}];
          for my $filter (@$filters) {
            if ($filter =~ /\A($NamePattern):([1-9][0-9]+)\z/o) {
              my $name = $1;
              my $value = $2;
              $items = [grep {
                if (defined $_->{data}->{$name} and
                    $_->{data}->{$name} eq $value) {
                  $_;
                } else {
                  ();
                }
              } @$items];
            } else {
              return $app->throw_error
                  (400, reason_phrase => 'Bad filter |'.$filter.'|');
            }
          }
          @$items = @$items[0..($page->{limit}-1)] if @$items > $page->{limit};
          my $next_page = next_page $page, $items, 'timestamp';
          return json $app, {objects => $items, %$next_page};
        });
      };
    }

    if (@$path == 2 and
        $path->[0] =~ /\A$NamePattern\z/o and
        $path->[1] eq 'create.json') {
      # /{name}/create.json
      $app->requires_request_method ({POST => 1});
      $app->requires_same_origin;
      return with_db {
        my $db = shift;
        return $db->execute ('select uuid_short() as uuid', undef, source_name => 'master')->then (sub {
          my $id = $_[0]->first->{uuid};
          my $data = {};
          for (keys %{$app->http->request_body_params}) {
            $data->{$_} = $app->text_param ($_);
          }
          return $db->insert ('object', [{
            id => $id,
            type => Dongry::Type->serialize ('text', $path->[0]),
            data => Dongry::Type->serialize ('json', $data),
            timestamp => time,
          }])->then (sub {
            return json $app, {
              object_id => ''.$id,
              object_type => $path->[0],
            };
          });
        });
      };
    }

    if (@$path == 2 and
        $path->[0] eq 'css' and $path->[1] =~ /\A[A-Za-z0-9-]+\.css\z/) {
      return static $app, 'css', $path->[1];
    }

    if (@$path == 3 and
        $path->[0] eq 'css' and
        $path->[1] eq 'core' and
        $path->[2] =~ /\A[A-Za-z0-9-]+\.css\z/) {
      return static $app, 'css_core', $path->[2];
    }

    if (@$path == 2 and
        $path->[0] eq 'js' and $path->[1] =~ /\A[A-Za-z0-9-]+\.js\z/) {
      return static $app, 'js', $path->[1];
    }

    if (@$path == 3 and
        $path->[0] eq 'js' and
        $path->[1] eq 'core' and
        $path->[2] =~ /\A[A-Za-z0-9-]+\.js\z/) {
      return static $app, 'js_core', $path->[2];
    }

    return $app->throw_error (404);
  });
};

=head1 LICENSE

Copyright 2017 Wakaba <wakaba@suikawiki.org>.

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
