# $Id: Makefile.PL 3580 2010-08-18 22:51:54Z bawden $

use strict;
use warnings;
use ExtUtils::MakeMaker;

sub MY::postamble {
    my @files = ();
    open(MANIFEST, "MANIFEST");
    while (<MANIFEST>) {
	if (m(^(\S+))) {
	    push(@files, $1);
	}
    }
    <<"EOF";

TAGS: @files
	etags @files

EOF
}

WriteMakefile(
    NAME		=> 'RDFHerd',
    AUTHOR		=> 'Alan Bawden <Bawden@CreativeCommons.Org>',
    VERSION		=> '1.18.1',
    ABSTRACT		=> 'Tools for managing herds of RDF.',
    PL_FILES		=> {},
    EXE_FILES		=> [ 'bin/rdfherd' ],
    PREREQ_PM		=> {
	'Cwd'			=> 0,
	'DBD::ODBC'		=> 0,
	'DBI'			=> 0,
	'DB_File'		=> 0,
	'File::Copy'		=> 0,
	'Getopt::Long'		=> 0,
	'Safe'			=> 0,
	'Sys::Hostname'		=> 0,
	'Term::ReadKey'		=> 0,
	'Test::More'		=> 0,
	'Time::HiRes'		=> 0,
    },
    dist		=> { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean		=> { FILES => 'RDFHerd-*' },
    );
