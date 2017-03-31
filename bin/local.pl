use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->child ('t_deps/lib');
use lib glob path (__FILE__)->parent->parent->child ('t_deps/modules/*/lib');
BEGIN {
  $ENV{WEBUA_DEBUG} //= 1;
  $ENV{WEBSERVER_DEBUG} //= 1;
  $ENV{PROMISED_COMMAND_DEBUG} //= 1;
  $ENV{SQL_DEBUG} //= 1;
}
use TestServers;

my $json_file = shift or die "perl $0 json-file";

TestServers->servers (
  port => 6631,
  json_path => path ($json_file),
  send_info => sub {
    my $info = shift;
    printf STDERR "Server: %s\n", $info->{url}->stringify;
  },
)->then (sub {
  print STDERR "Type C-c to terminate the server.\n";
  return $_[0]->[1]->();
})->to_cv->recv;

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
