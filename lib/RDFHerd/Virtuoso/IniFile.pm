# A Virtuoso .ini file.
#
# Copyright © 2008  Creative Commons Corp.
#
# $Id: IniFile.pm 3580 2010-08-18 22:51:54Z bawden $

package RDFHerd::Virtuoso::IniFile;

use 5.008_005;
use strict;
use integer;
use Carp;
use English '-no_match_vars';
use File::Copy qw(copy);
use RDFHerd::Utils qw(exit_check);
#use Fcntl qw(O_RDONLY);
#use FileHandle;
#use POSIX qw();

our (@ISA, $VERSION);
@ISA = qw();
$VERSION = 1.18_01;

sub new {
    (@_ == 4) or confess "\tBUG";
    my ($class, $tool, $file, $template) = @_;
    unless (-e $file) {
	copy($template, $file)
	    or die "$ERRNO: copying $template to $file\n";
    }
    (-w $file)
	or die "I don't seem to have write access to $file\n";
    (-x $tool)
	or die "I can't seem to execute $tool\n";
    my $self = {
	tool => $tool,
	file => $file,
    };
    bless $self, $class;
    return $self;
}

sub get {
    (@_ == 3) or confess "\tBUG";
    my ($self, $section, $key) = @_;
    my $tool = $self->{tool};
    my $file = $self->{file};
    my $val = qx"$tool -n -f \Q$file\E -s \Q$section\E -k \Q$key\E";
    defined($val) or exit_check($tool);
    chomp $val;
    return $val;
}

sub put {
    (@_ == 4) or confess "\tBUG";
    my ($self, $section, $key, $val) = @_;
    my $tool = $self->{tool};
    my $file = $self->{file};
    my $rv = qx"$tool -n -f \Q$file\E -s \Q$section\E -k \Q$key\E -v \Q$val\E";
    defined($rv) or exit_check($tool);
}

sub exch {
    (@_ == 4) or confess "\tBUG";
    my ($self, $section, $key, $val) = @_;
    my $rv = $self->get($section, $key);
    $self->put($section, $key, $val);
    return $rv;
}

sub clear {
    (@_ == 3) or confess "\tBUG";
    my ($self, $section, $key) = @_;
    $self->put($section, $key, "-");
}

sub exch_clear {
    (@_ == 3) or confess "\tBUG";
    my ($self, $section, $key) = @_;
    return $self->exch($section, $key, "-");
}

sub write_array {
    (@_ == 4) or confess "\tBUG";
    my ($self, $section, $key, $aref) = @_;
    my $i = 1;
    for my $val (@{$aref}) {
	$self->put($section, $key . $i, $val);
	$i++;
    }
    while ($self->exch_clear($section, $key . $i)) {
	$i++;
    }
}

1;
__END__

# Local Variables:
# mode: Perl
# End:
