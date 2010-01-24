package SVN::Dump::Change::Mkdir;

use Moose;
extends 'SVN::Dump::Change';

has '+callback' => ( default => 'on_directory_creation' );

1;
