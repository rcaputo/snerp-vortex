package SVN::Dump::Change::Rmfile;

use Moose;
extends 'SVN::Dump::Change::Rm';

has '+operation' => ( default => 'file_deletion' );

1;
