package SVN::Dump::Change::Rename;

use Moose;
extends 'SVN::Dump::Change::Copy';

has '+operation' => ( default => 'rename' );

1;
