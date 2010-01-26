#!/usr/bin/env perl

use warnings;
use strict;
use lib qw(./lib);

my $authors_file    = "/home/troc/projects/authors.txt";
my $svn_replay_base = "/Volumes/snerp-vortex-workspace/poe-replay";
my $svn_dump_file   = "/home/troc/projects/git/poe-svn.dump";
my $svn_cp_src_dir  = "/Volumes/snerp-vortex-workspace/poe-copy-sources";

system("rm -rf $svn_replay_base") and die $!;
system("mkdir $svn_replay_base") and die $!;

system("rm -rf $svn_cp_src_dir") and die $!;
system("mkdir $svn_cp_src_dir") and die $!;

my $replayer = SVN::Dump::Replayer->new(
	svn_dump_filename => $svn_dump_file,
	svn_replay_base   => $svn_replay_base,
	copy_source_depot => $svn_cp_src_dir,
);

$replayer->walk();
