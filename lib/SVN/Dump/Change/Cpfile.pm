package SVN::Dump::Change::Cpfile;

use Moose;
extends 'SVN::Dump::Change::Copy';

has '+operation' => ( default => 'file_copy' );

1;
