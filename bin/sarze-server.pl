use strict;
use warnings;
use Path::Tiny;
use Sarze;

my $host = '0';
my $port = shift or die "Usage: $0 port json-path";
my $path = shift or die "Usage: $0 port json-path";

$ENV{APP_JSON_PATH} = $path;

Sarze->run (
  hostports => [
    [$host, $port],
  ],
  psgi_file_name => path (__FILE__)->parent->child ('server.psgi'),
)->to_cv->recv;
