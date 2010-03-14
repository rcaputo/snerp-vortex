package SVN::Analysis::Change::Delete;

use Moose;
extends 'SVN::Analysis::Change';

sub is_add    { 0 }
sub is_copy   { 0 }
sub is_delete { 1 }
sub is_touch  { 0 }
sub exists    { 0 }

1;
