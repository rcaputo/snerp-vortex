package SVN::Dump::Change::Rmfile;

use Moose;
extends 'SVN::Dump::Change::Rm';

has '+callback' => ( default => 'on_file_deletion' );

1;
