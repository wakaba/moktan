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

    if (@$path == 2 and
        $path->[0] =~ /$NamePattern/o and
        $path->[1] eq 'create.json') {
      # /{name}/create.json
      $app->requires_request_method ({POST => 1});
      $app->requires_same_origin;
      return with_db {
        my $db = shift;
        return $db->execute ('select uuid_short() as uuid', undef, source_name => 'master')->then (sub {
          my $id = $_[0]->first->{uuid};
          my $data = {};
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
License along with this program, see <http://www.gnu.org/licenses/>.

=cut
