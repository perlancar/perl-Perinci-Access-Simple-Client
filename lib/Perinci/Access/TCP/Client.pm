package Perinci::Access::TCP::Client;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use IO::Socket::INET;
use IO::Socket::UNIX;
use Tie::Cache;
use URI;

use parent qw(Perinci::Access::Base);

# VERSION

my @logging_methods = Log::Any->logging_methods();

sub _init {
    my ($self) = @_;

    # attributes
    $self->{retries}         //= 2;
    $self->{retry_delay}     //= 3;

    # connection cache, key=host:port OR unixpath, value=socket
    tie my(%conns), 'Tie::Cache', 32;
    $self->{_conns} = \%conns;
}

sub request {
    require JSON;

    my ($self, $action, $server_url, $extra) = @_;
    $log->tracef("=> %s\::request(action=%s, server_url=%s, extra=%s)",
                 __PACKAGE__, $action, $server_url, $extra);
    return [400, "Please specify server_url"] unless $server_url;
    my $req = { action=>$action, %{$extra // {}} };
    my $res = $self->check_request($req);
    return $res if $res;

    my ($host, $port, $unix, $uri);
    $server_url = URI->new($server_url) unless ref($server_url);
    return [400, "Please supply only riap+tcp URL"]
        unless $server_url->scheme eq 'riap+tcp';
    my $opaque = $server_url->opaque;
    if ($opaque =~ m!^//!) {
        if ($opaque =~ m!^//([^:/]+):(\d+)(/.*)!) {
            ($host, $port, $uri) = ($1, $2, $3);
        } else {
            return [400, "Invalid URL, please supply host + port"];
        }
    } else {
        if ($opaque =~ m!(.+?)/(/.*)!) {
            ($unix, $uri) = ($1, $2);
            $unix = "/$unix" unless $unix =~ m!^/!;
        } else {
            return [400,
                    "Invalid URL, when specifying Unix socket, please use // ".
                        "to separate it with Riap URI, e.g. " .
                        "riap+tcp:/path/to/unix/socket//Foo/Bar/func"
                    ];
        }
    }
    $req->{uri} = $uri;

    state $json = JSON->new->allow_nonref;

    my $attempts = 0;
    my $do_retry;
    my $e;
    while (1) {
        $do_retry = 0;

        my $key = $unix ? $unix : "$host:$port";
        my $sock = $self->{_conns}{$key};
        if ($sock) {
            if (!$sock->connected) {
                $e = "Stale socket cache";
                goto RETRY;
            }
        } elsif ($unix) {
            $sock = IO::Socket::UNIX->new(
                Type => SOCK_STREAM,
                Peer => $unix
            );
            $e = $@;
            if ($sock) {
                $self->{_conns}{$key} = $sock;
            } else {
                $e = "Can't connect to Unix socket $unix: $e";
                $do_retry++; goto RETRY;
            }
        } else {
            $sock = IO::Socket::INET->new(
                PeerHost => $host,
                PeerPort => $port,
                Proto    => 'tcp',
            );
            $e = $@;
            if ($sock) {
                $self->{_conns}{$key} = $sock;
            } else {
                $e = "Can't connect to TCP socket $host:$port: $e";
                $do_retry++; goto RETRY;
            }
        }

        my $req_json;
        eval { $req_json = $json->encode($req) };
        $e = $@;
        return [400, "Can't encode request as JSON: $e"] if $e;

        $sock->syswrite("J" . length($req_json) . "\015\012");
        $sock->syswrite($req_json);
        $sock->syswrite("\015\012");
        $log->tracef("Sent request to server: %s", $req_json);

        # XXX alarm/timeout
        my $line = $sock->getline;
        $log->tracef("Got line from server: %s", $line);
        if (!$line) {
            delete $self->{_conns}{$key};
            return [500, "Empty response from server"];
        } elsif ($line !~ /^J(\d+)/) {
            delete $self->{_conns}{$key};
            return [500, "Invalid response line from server: $line"];
        }
        my $res_json;
        $log->tracef("Reading $1 bytes from server ...");
        $sock->read($res_json, $1);
        $log->tracef("Got from server: %s", $res_json);
        $sock->getline; # CRLF after response
        eval { $res = $json->decode($res_json) };
        $e = $@;
        if ($e) {
            return [500, "Invalid JSON response from server: $e"];
        }
        return $res;

      RETRY:
        if ($do_retry && $attempts++ < $self->{retries}) {
            $log->tracef("Request failed ($e), waiting to retry #%s...",
                         $attempts);
            sleep $self->{retry_delay};
        } else {
            last;
        }
    }
    return [500, "$e (retried)"];
}

1;
# ABSTRACT: Riap::TCP client

=for Pod::Coverage ^action_.+

=cut

=head1 SYNOPSIS

 use Perinci::Access::TCP::Client;
 my $pa = Perinci::Access::TCP::Client->new;

 my $res;
 $res = $pa->request(call => 'riap+tcp://localhost:5678/Foo/Bar/func',
                     {args => {a1=>1, a2=>2}});
 $res = $pa->request(call => 'riap+tcp://localhost:5678/Foo/Bar/func',
                     {args => {a1=>1, a2=>2}});


=head1 DESCRIPTION

This class implements L<Riap::TCP> client.

This class uses L<Log::Any> for logging.


=head1 METHODS

=head2 PKG->new(%attrs) => OBJ

Instantiate object. Known attributes:

=over 4

=item * retries => INT (default 2)

Number of retries to do on network failure. Setting it to 0 will disable
retries.

=item * retry_delay => INT (default 3)

Number of seconds to wait between retries.

=back

=head2 $pa->request($action => $server_url, \%extra) => $res

Send Riap request to $server_url.


=head1 SEE ALSO

L<Perinci::Access::TCP::Server>

L<Riap>, L<Rinci>

=cut
