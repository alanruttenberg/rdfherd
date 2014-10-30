#!perl -T
# $Id: 00-load.t 1882 2008-06-09 17:32:11Z bawden $

use Test::More tests => 10;

BEGIN {
	use_ok( 'RDFHerd' );
	use_ok( 'RDFHerd::Utils' );
	use_ok( 'RDFHerd::CacheUtils' );
	use_ok( 'RDFHerd::Term' );
	use_ok( 'RDFHerd::Log' );
	use_ok( 'RDFHerd::Bundle' );
	use_ok( 'RDFHerd::Server' );
	use_ok( 'RDFHerd::Virtuoso::IniFile' );
	use_ok( 'RDFHerd::Virtuoso::Server' );
	use_ok( 'RDFHerd::CTest' );
}

diag( "Testing RDFHerd $RDFHerd::VERSION, Perl $], $^X" );
