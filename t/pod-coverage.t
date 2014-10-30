#!perl -T
# $Id: pod-coverage.t 1882 2008-06-09 17:32:11Z bawden $

use Test::More;
eval "use Test::Pod::Coverage 1.04";
plan skip_all => "Test::Pod::Coverage 1.04 required for testing POD coverage" if $@;
#all_pod_coverage_ok();

plan tests => 10;
TODO: {
    local $TODO = "I'm not not sure its worth it to do these...";
    pod_coverage_ok( 'RDFHerd' );
    pod_coverage_ok( 'RDFHerd::Utils' );
    pod_coverage_ok( 'RDFHerd::CacheUtils' );
    pod_coverage_ok( 'RDFHerd::Term' );
    pod_coverage_ok( 'RDFHerd::Log' );
    pod_coverage_ok( 'RDFHerd::Bundle' );
    pod_coverage_ok( 'RDFHerd::Server' );
    pod_coverage_ok( 'RDFHerd::Virtuoso::IniFile' );
    pod_coverage_ok( 'RDFHerd::Virtuoso::Server' );
    pod_coverage_ok( 'RDFHerd::CTest' );
}
