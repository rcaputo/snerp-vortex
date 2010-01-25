package SVN::Dump::Change::Rmdir;

use Moose;
extends 'SVN::Dump::Change::Rm';

has '+operation' => ( default => 'directory_deletion' );

1;
