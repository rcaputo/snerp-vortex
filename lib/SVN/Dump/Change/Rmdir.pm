package SVN::Dump::Change::Rmdir;

use Moose;
extends 'SVN::Dump::Change::Rm';

has '+callback' => ( default => 'on_directory_deletion' );

1;
