package Perinci::Access::Simple::Client;

use 5.010001;
use strict;
use warnings;
use Log::Any '$log';

use Cwd qw(abs_path);
use POSIX qw(:sys_wait_h);
use Tie::Cache;
use URI;
use URI::Escape;

use parent qw(Perinci::Access::Base);

# VERSION

my @logging_methods = Log::Any->logging_methods();

sub _init {
    my ($self) = @_;

    # attributes
    $self->{retries}         //= 2;
    $self->{retry_delay}     //= 3;
    $self->{conn_cache_size} //= 32;

    # connection cache, key="tcp:HOST:PORT" OR "unix:ABSPATH" or "pipe:ABSPATH
    # ARGS". value=hash, for tcp & unix {socket=>...} and for pipe {pid=>...,
    # chld_out=>..., chld_in=>...}
    tie my(%conns), 'Tie::Cache', $self->{conn_cache_size};
    $self->{_conns} = \%conns;
}

sub _delete_cache {
    my ($self, $wanted) = @_;
    my $conns = $self->{_conns};
    return unless $conns;

    for my $k ($wanted ? ($wanted) : (keys %$conns)) {
        if ($k =~ /^pipe:/) {
            waitpid($conns->{$k}{pid}, WNOHANG);
        }
        delete $self->{_conns}{$k};
    }
}

sub DESTROY {
    my ($self) = @_;

    #$self->_delete_cache;
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

    my ($uri,
        $cache_key,
        $host, $port, # tcp
        $path,        # unix & pipe
        $args         # pipe
    );
    $server_url = URI->new($server_url) unless ref($server_url);
    my $scheme = $server_url->scheme;
    return [400, "Please supply only riap+tcp/riap+unix/riap+pipe URL"]
        unless $scheme =~ /\Ariap\+(tcp|unix|pipe)\z/;
    my $opaque = $server_url->opaque;
    if ($scheme eq 'riap+tcp') {
        if ($opaque =~ m!^//([^:/]+):(\d+)(/.*)!) {
            ($host, $port, $uri) = ($1, $2, $3);
            $cache_key = "tcp:".lc($host).":$port";
        } else {
            return [400, "Invalid URL, please supply host : port / entity uri".
                ", e.g.: riap+tcp://localhost:5000/Foo/Bar/func"];
        }
    } elsif ($scheme eq 'riap+unix') {
        if ($opaque =~ m!(.+?)/(/.*)!) {
            ($path, $uri) = (uri_unescape($1), $2);
            my $apath = abs_path($path) or
                return [500, "Can't find absolute path for $path"];
            $cache_key = "unix:$apath";
        } else {
            return [400, "Invalid URL, please supply path // entity uri".
                ", e.g.: riap+unix:/path/to/unix/socket//Foo/Bar/func"];
        }
    } elsif ($scheme eq 'riap+pipe') {
        if ($opaque =~ m!(.+?)//(.*?)/(/.*)!) {
            ($path, $args, $uri) = (uri_unescape($1), $2, $3);
            my $apath = abs_path($path) or
                return [500, "Can't find absolute path for $path"];
            $args = [map {uri_unescape($_)} split m!/!, $args];
            $cache_key = "pipe:$apath ".join(" ", @$args);
        } else {
            return [
                400,
                "Invalid URL, please supply path // args // entity uri, e.g: ".
                    "riap+pipe:/path/to/prog//arg1/arg2//Foo/Bar/func"];
        }
    }
    $log->tracef("Parsed URI, scheme=%s, host=%s, port=%s, path=%s, args=%s, ".
                     "ceuri=%s", $scheme, $host, $port, $path, $args, $uri);
    $req->{uri} = $uri;

    state $json = JSON->new->allow_nonref;

    my $attempts = 0;
    my $do_retry;
    my $e;
    while (1) {
        $do_retry = 0;

        my ($in, $out);
        my $cache = $self->{_conns}{$cache_key};
        # check cache staleness
        if ($cache) {
            if ($scheme =~ /tcp|unix/) {
                if ($cache->{socket}->connected) {
                    $in = $out = $cache->{socket};
                } else {
                    $log->infof("Stale socket cache (%s), discarded",
                                $cache_key);
                    $cache = undef;
                }
            } else {
                if (kill(0, $cache->{pid})) {
                    $in  = $cache->{chld_out};
                    $out = $cache->{chld_in};
                } else {
                    $log->infof(
                        "Process (%s) seems dead/unsignalable, discarded",
                        $cache_key);
                    $cache = undef;
                }
            }
        }
        # connect
        if (!$cache) {
            if ($scheme =~ /tcp|unix/) {
                my $sock;
                if ($scheme eq 'riap+tcp') {
                    require IO::Socket::INET;
                    $sock = IO::Socket::INET->new(
                        PeerHost => $host,
                        PeerPort => $port,
                        Proto    => 'tcp',
                    );
                } else {
                    use IO::Socket::UNIX;
                    $sock = IO::Socket::UNIX->new(
                        Type => SOCK_STREAM,
                        Peer => $path,
                    );
                }
                $e = $@;
                if ($sock) {
                    $self->{_conns}{$cache_key} = {socket=>$sock};
                    $in = $out = $sock;
                } else {
                    $e = $scheme eq 'riap+tcp' ?
                        "Can't connect to TCP socket $host:$port: $e" :
                            "Can't connect to Unix socket $path: $e";
                    $do_retry++; goto RETRY;
                }
            } else {
                # taken from Modern::Perl. enable methods on filehandles;
                # unnecessary when 5.14 autoloads them
                require IO::File;
                require IO::Handle;

                require IPC::Open2;

                require String::ShellQuote;
                my $cmd = $path . (@$args ? " " . join(" ", map {
                    String::ShellQuote::shell_quote($_) } @$args) : "");

                # using shell
                #my $pid = IPC::Open2::open2($in, $out, $cmd, @$args);

                # not using shell
                my $pid = IPC::Open2::open2($in, $out, $path, @$args);

                if ($pid) {
                    $self->{_conns}{$cache_key} = {
                        pid=>$pid, chld_out=>$in, chld_in=>$out};
                } else {
                    $e = "Can't open2 $cmd: $!";
                    $do_retry++; goto RETRY;
                }
            }
        }

        my $req_json;
        eval { $req_json = $json->encode($req) };
        $e = $@;
        return [400, "Can't encode request as JSON: $e"] if $e;

        if (length($req_json) > 1000) {
            $out->write("J" . length($req_json) . "\015\012");
            $out->write($req_json);
            $out->write("\015\012");
        } else {
            $out->write("j$req_json\015\012");
        }
        $log->tracef("Sent request to server: %s", $req_json);

        # XXX alarm/timeout
        my $line = $in->getline;
        $log->tracef("Got line from server: %s", $line);
        if (!$line) {
            $self->_delete_cache($cache_key);
            return [500, "Empty response from server"];
        } elsif ($line !~ /^J(\d+)/) {
            $self->_delete_cache($cache_key);
            return [500, "Invalid response line from server: $line"];
        }
        my $res_json;
        $log->tracef("Reading $1 bytes from server ...");
        $in->read($res_json, $1);
        $log->tracef("Got from server: %s", $res_json);
        $in->getline; # CRLF after response
        eval { $res = $json->decode($res_json) };
        $e = $@;
        if ($e) {
            $self->_delete_cache($cache_key);
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
# ABSTRACT: Riap::Simple client

=head1 SYNOPSIS

 use Perinci::Access::Simple::Client;
 my $pa = Perinci::Access::Simple::Client->new;

 my $res;

 # to request server over TCP
 $res = $pa->request(call => 'riap+tcp://localhost:5678/Foo/Bar/func',
                     {args => {a1=>1, a2=>2}});

 # to request server over Unix socket (separate Unix socket path and Riap
 # request key 'uri' with an extra slash /)
 $res = $pa->request(call => 'riap+unix:/var/run/api.sock//Foo/Bar/func',
                     {args => {a1=>1, a2=>2}});

 # to request "server" (program) over pipe (separate program path and first
 # argument with an extra slash /, then separate each program argument with
 # slashes, finally separate last program argument with Riap request key 'uri'
 # with an extra slash /). Arguments are URL-escaped so they can contain slashes
 # if needed (in the encoded form of %2F).
 $res = $pa->request(call => 'riap+pipe:/path/to/prog//arg1/arg2//Foo/Bar/func',
                     {args => {a1=>1, a2=>2}});

 # an example for riap+pipe, accessing a remote program via SSH client
 use URI::Escape;
 my @cmd = ('ssh', '-T', 'user@host', '/path/to/program', 'first arg', '2nd');
 my $uri = "/Foo/Bar/func";
 $res = $pa->request(call => 'riap+pipe:' .
                             uri_escape($cmd[0]) . '//' .
                             join('/', map { uri_escape($_) } @cmd[1..@cmd-1]) . '/' .
                             $uri,
                     {args => {a1=>1, a2=>2}});


=head1 DESCRIPTION

This class implements L<Riap::Simple> client. It supports the 'riap+tcp',
'riap+unix', and 'riap+pipe' schemes for a variety of methods to access the
server: either via TCP (where the server can be on a remote computer), Unix
socket, or a program (where the program can also be on a remote computer, e.g.
accessed via ssh).

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

L<Perinci::Access::Simple::Server>

L<Riap::Simple>, L<Riap>, L<Rinci>

=cut
