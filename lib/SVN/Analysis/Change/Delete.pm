package SVN::Analysis::Change::Delete;

use Moose;
extends 'SVN::Analysis::Change';

sub is_delete { 1 }

1;
