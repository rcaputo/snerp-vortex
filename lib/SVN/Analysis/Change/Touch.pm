package SVN::Analysis::Change::Touch;

use Moose;
extends 'SVN::Analysis::Change::Exists';

sub is_touch { 1 }

1;
