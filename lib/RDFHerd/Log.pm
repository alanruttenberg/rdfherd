# Put a log in front of a database.
#
# Copyright © 2008-2010  Creative Commons Corp.
#
# $Id: Log.pm 3580 2010-08-18 22:51:54Z bawden $

package RDFHerd::Log;

use 5.008_005;
use strict;
use integer;
use Carp;
use English '-no_match_vars';
use Fcntl qw(O_RDONLY O_WRONLY O_APPEND O_CREAT);
use FileHandle;
use RDFHerd::Utils qw(read_hash write_hash);

our (@ISA, $VERSION);
@ISA = qw();
$VERSION = 1.18_01;

# Presumably the DB is tied to something like a DB_File, but that isn't our
# concern, we just treat it as an ordinary hash.
sub new {
    (@_ == 7) or confess "\tBUG";
    my ($class, $path, $db, $version_wanted, $init_db, $init_scratch, $proc) = @_;
    my ($sync, $version);
    my $scratch = {};
    my $scratch_initialized = 0;
    my $mode = O_WRONLY | O_APPEND;
    my $fh = new FileHandle;
    if (exists($db->{LOG_SYNC}) && exists($db->{CACHE_VERSION})) {
	$sync = $db->{LOG_SYNC};
	$version = $db->{CACHE_VERSION};
    } else {
	&$init_db($db);
	$db->{LOG_SYNC} = 0;
	$db->{CACHE_VERSION} = $version_wanted;
	$sync = 0;
	$version = $version_wanted;
    }
    if (-e $path) {
	(-f _) or croak "Not a regular file: $path";
	(-r _) or croak "Can't read: $path";
	(-w _) or croak "Can't write: $path";
	my $len = -s _;
	if ($len < $sync) {
	    croak "Log file too short: $path";
	}
	if ($len > $sync || $version != $version_wanted) {
	    warn "Rebuilding database...\n";
	    $fh->open($path, O_RDONLY) or croak "$ERRNO: $path";
	    &$init_db($db);
	    &$init_scratch($db, $scratch);
	    $scratch_initialized = 1;
	    while (my $hashref = read_hash($fh)) {
		&$proc($hashref, $db, $scratch);
	    }
	    $fh->close() or confess "\tBUG";
	    $db->{LOG_SYNC} = $len;
	    $db->{CACHE_VERSION} = $version_wanted;
	}
    } elsif ($sync > 0) {
	croak "Log file missing: $path";
    } else {
	$mode |= O_CREAT;
    }
    $scratch_initialized or &$init_scratch($db, $scratch);

    $fh->open($path, $mode) or croak "$ERRNO: $path";
    # You might be tempted to check that $fh->tell() == $db->{LOG_SYNC}
    # right here, but that won't work because O_APPEND won't move to the
    # end of the file until after the first call to write().
    my $self = {
	db => $db,
	scratch => $scratch,
	proc => $proc,
	fifo => [],
	fh => $fh,
    };
    bless($self, $class);
    return $self;
}

sub close {
    my ($self) = @_;
    my $fh = $self->{fh};
    if ($fh) {
	$self->sync();
	$self->{fh} = undef;
	return $fh->close();
    }
    return 1;
}

sub write {
    (@_ == 2) or confess "\tBUG";
    my ($self, $hashref) = @_;
    push(@{$self->{fifo}}, $hashref);
}

sub sync {
    my ($self) = @_;
    my $fifo = $self->{fifo};
    return if (@$fifo == 0);
    my $fh = $self->{fh} or croak "Log closed.";
    for my $hashref (@$fifo) {
	write_hash($fh, $hashref);
    }
    $fh->flush() or confess "\tBUG";
    $fh->sync() or confess "\tBUG";
    my $sync = $fh->tell();
    ($sync >= 0) or confess "\tBUG";
    my $proc = $self->{proc};
    my $db = $self->{db};
    my $scratch = $self->{scratch};
    for my $hashref (@$fifo) {
	&$proc($hashref, $db, $scratch);
    }
    $self->{fifo} = [];
    $db->{LOG_SYNC} = $sync;
}

1;
__END__

# Local Variables:
# mode: Perl
# End:
