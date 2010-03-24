package SVN::Dump::Change::Copy;

use Moose;
extends 'SVN::Dump::Change';

has src_rev       => ( is => 'ro', isa => 'Int', required => 1 );
has src_path      => ( is => 'ro', isa => 'Str', required => 1 );
has src_analysis  => (
	is => 'rw',
	isa => 'SVN::Analysis::Change',
);

has src_entity  => (
	is      => 'rw',
	isa     => 'SVN::Analysis::Change',
	handles => {
		src_entity_type => 'entity_type',
		src_entity_name => 'entity_name',
	},
);

sub src_rel_path {
	my $self = shift;
	return $self->analysis()->fix_path($self->src_path());
}

1;
