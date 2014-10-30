# Test class.
#
# Copyright © 2008-2010  Creative Commons Corp.
#
# $Id: CTest.pm 3580 2010-08-18 22:51:54Z bawden $

package RDFHerd::CTest;

use 5.008_005;
use strict;
use integer;
use RDFHerd::Utils qw(check_class_version);
#use Carp;
#use Cwd qw(abs_path);
#use English '-no_match_vars';
#use Fcntl qw(O_RDONLY);
#use FileHandle;
#use POSIX qw();

our (@ISA, $VERSION);
@ISA = qw(RDFHerd);
$VERSION = 1.18_01;

sub _new {
    my ($class, $class_name, $path, $cfg) = @_;
    check_class_version(1, 3, $path, $cfg);
    my $self = {
	class_name => "Test",
	state_file => "$path/State",
    };
    bless($self, $class);
    return $self;
}

1;
__END__

# Local Variables:
# mode: Perl
# End:
