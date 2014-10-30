# Terms
#
# Copyright © 2008-2010  Creative Commons Corp.
#
# $Id: Term.pm 3580 2010-08-18 22:51:54Z bawden $
#
# Note that nothing at all uses this right now.  It's a half-baked idea
# that was never useful.

package RDFHerd::Term;

use 5.008_005;
use strict;
use integer;
use Carp;
use RDFHerd::Utils qw(make_constructor);

our (@ISA, $VERSION);
@ISA = qw();
$VERSION = 1.18_01;

# Constructors call C<bless> with just one argument so that you can safely
# call them from inside a "compartment" created by the the Safe module.  If
# you want to make a sub-class of this class, you'll have to deal with
# that...

sub constructor ($$$$%) {
    my ($operator, $p, $r, $o, %d) = @_;
    my %keys;
    for my $k (@$p, @$r, @$o, keys(%d)) {
	$keys{$k} = 1;
    }
    if ($keys{TYPE}) {
	confess "You can't use TYPE as a key";
    }
    $d{TYPE} = [$operator, \%keys];
    my $make_hash = make_constructor($p, $r, $o, %d);
    return sub {
	my $self = &$make_hash(@_);
	bless($self);		# See above
	return $self;
    }
}

sub operator { $_[0]->{TYPE}->[0] }
sub keys { $_[0]->{TYPE}->[1] }

1;
__END__

# Local Variables:
# mode: Perl
# End:
