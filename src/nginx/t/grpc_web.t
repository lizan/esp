# Copyright (C) Extensible Service Proxy Authors
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
################################################################################
#
use strict;
use warnings;

################################################################################

use src::nginx::t::ApiManager;   # Must be first (sets up import path to the Nginx test module)
use src::nginx::t::HttpServer;
use src::nginx::t::ServiceControl;
use Test::Nginx;  # Imports Nginx's test module
use Test::More;   # And the test framework
use JSON::PP;

################################################################################

# Port assignments
my $NginxPort = ApiManager::pick_port();
my $ServiceControlPort = ApiManager::pick_port();
my $GrpcServerPort = ApiManager::pick_port();

my $t = Test::Nginx->new()->has(qw/http proxy/)->plan(12);

$t->write_file('service.pb.txt',
  ApiManager::get_transcoding_test_service_config(
    'endpoints-transcoding-test.cloudendpointsapis.com',
    "http://127.0.0.1:${ServiceControlPort}") .
    ApiManager::read_test_file('testdata/logs_metrics.pb.txt'));

$t->write_file('server_config.pb.txt', ApiManager::disable_service_control_cache);

$t->write_file_expand('nginx.conf', <<EOF);
%%TEST_GLOBALS%%
daemon off;

events {
  worker_connections 32;
}
http {
  %%TEST_GLOBALS_HTTP%%
  server_tokens off;
  server {
    listen 127.0.0.1:${NginxPort};
    server_name localhost;
    location / {
      endpoints {
        api service.pb.txt;
        server_config server_config.pb.txt;
        on;
      }
      grpc_pass 127.0.0.1:${GrpcServerPort};
      grpc_gateway_pass 127.0.0.1:${GrpcServerPort};
    }
  }
}
EOF

my $report_done = 'report_done';

$t->run_daemon(\&service_control, $t, $ServiceControlPort, 'servicecontrol.log', $report_done);
ApiManager::run_transcoding_test_server($t, 'server.log', "127.0.0.1:${GrpcServerPort}");

is($t->waitforsocket("127.0.0.1:${ServiceControlPort}"), 1, "Service control socket ready.");
is($t->waitforsocket("127.0.0.1:${GrpcServerPort}"), 1, "GRPC test server socket ready.");
$t->run();
is($t->waitforsocket("127.0.0.1:${NginxPort}"), 1, "Nginx socket ready.");

################################################################################

my $initial_shelves_response = ApiManager::http($NginxPort, <<EOF . "\x00\x00\x00\x00\x00\x0a");
POST /endpoints.examples.bookstore.Bookstore/ListShelves HTTP/1.1
host: 127.0.0.1:${NginxPort}
x-api-key: api-key
connection: close
content-type: application/grpc-web
content-length: 5

EOF

# Wait for the service control report
is($t->waitforfile("$t->{_testdir}/${report_done}"), 1, 'Report body file ready.');
$t->stop_daemons();

# Check the requests that the backend has received
my $initial_shelves_request_expected = {};

my $server_output = $t->read_file('server.log');
my @server_requests = split /\r\n\r\n/, $server_output;

ok(ApiManager::compare_json($server_requests[0], $initial_shelves_request_expected));

like($initial_shelves_response, qr/HTTP\/1\.1 200 OK/, 'Returned HTTP 200 OK');
like($initial_shelves_response, qr/Content-Type: application\/grpc-web/i,
     'Returned application/grpc-web header.');
like($initial_shelves_response, qr/grpc-status: 0/i,
     "Returned grpc-status trailer.");


# Expect 2 service control calls for 1 requests.
my @servicecontrol_requests = ApiManager::read_http_stream($t, 'servicecontrol.log');
is(scalar @servicecontrol_requests, 2, 'Service control was called 2 times');

while (my ($i, $r) = each @servicecontrol_requests) {
  if ($i % 2 == 0) {
    like($r->{uri}, qr/:check$/, "Check has correct uri for ${i}");
  } else {
    like($r->{uri}, qr/:report$/, "Report has correct uri for ${i}");
  }
}

# :check
my $r = shift @servicecontrol_requests;
my $check_body = ServiceControl::convert_proto($r->{body}, 'check_request', 'json');
my $expected_check_body = {
  'serviceName' => 'endpoints-transcoding-test.cloudendpointsapis.com',
  'serviceConfigId' => '2016-08-25r1',
  'operation' => {
     'consumerId' => 'api_key:api-key',
     'operationName' => 'endpoints.examples.bookstore.Bookstore.ListShelves',
     'labels' => {
        'servicecontrol.googleapis.com/caller_ip' => '127.0.0.1',
        'servicecontrol.googleapis.com/service_agent' => ServiceControl::service_agent(),
        'servicecontrol.googleapis.com/user_agent' => 'ESP',
     }
  }
};
ok(ServiceControl::compare_json($check_body, $expected_check_body), 'Check body is received.');

# :report
$r = shift @servicecontrol_requests;
my $report_body = ServiceControl::convert_proto($r->{body}, 'report_request', 'json');
my $expected_report_body = ServiceControl::gen_report_body({
  'serviceName' => 'endpoints-transcoding-test.cloudendpointsapis.com',
  'api_method' => 'endpoints.examples.bookstore.Bookstore.ListShelves',
  'serviceConfigId' => '2016-08-25r1',
  'url' => '/endpoints.examples.bookstore.Bookstore/ListShelves',
  'api_key' => 'api-key',
  'backend_protocol' => 'grpc',
  'producer_project_id' => 'endpoints-transcoding-test',
  'location' => 'us-central1',
  'api_name' =>  'endpoints.examples.bookstore.Bookstore',
  'api_version' =>  'v1',
  'http_method' => 'GET',
  'log_message' => 'Method: endpoints.examples.bookstore.Bookstore.ListShelves',
  'response_code' => '200',
  'request_size' => 51,
  'response_size' => 193,
  'request_bytes' => 51,
  'response_bytes' => 193,
  'streaming_request_message_counts' => 1,
  'streaming_response_message_counts' => 1,
  });
#ok(ServiceControl::compare_json($report_body, $expected_report_body), 'Report body is received.');

################################################################################

sub service_control {
  my ($t, $port, $file, $done) = @_;

  my $server = HttpServer->new($port, $t->testdir() . '/' . $file)
    or die "Can't create test server socket: $!\n";

  local $SIG{PIPE} = 'IGNORE';
  my $request_count = 0;

  $server->on_sub('POST', '/v1/services/endpoints-transcoding-test.cloudendpointsapis.com:check', sub {
    my ($headers, $body, $client) = @_;
    print $client <<EOF;
HTTP/1.1 200 OK
Content-Type: application/json
Connection: close

EOF
  });

  $server->on_sub('POST', '/v1/services/endpoints-transcoding-test.cloudendpointsapis.com:report', sub {
    my ($headers, $body, $client) = @_;
    print $client <<EOF;
HTTP/1.1 200 OK
Content-Type: application/json
Connection: close

EOF
    $request_count++;
    if ($request_count == 1) {
      $t->write_file($done, ":report done");
    }
  });

  $server->run();
}

################################################################################