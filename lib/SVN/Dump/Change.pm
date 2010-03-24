package SVN::Dump::Change;

use Moose;

has path      => ( is => 'ro', isa => 'Str', required => 1 );
has operation => ( is => 'ro', isa => 'Str' );

has analysis  => (
	is      => 'rw',
	isa     => 'SVN::Analysis::Change',
);

has entity  => (
	is      => 'rw',
	isa     => 'SVN::Analysis::Change',
	handles => [qw(entity_type entity_name)],
);

sub rel_path {
	my $self = shift;
	return $self->analysis()->fix_path($self->path());
}

1;
