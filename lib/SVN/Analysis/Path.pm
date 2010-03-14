package SVN::Analysis::Path;

use Moose;

has change => (
	is      => 'rw',
	isa     => 'ArrayRef[SVN::Analysis::Change]',
	default => sub { [ ] },
);

1;
