package SVN::Dump::Change::Copy;

use Moose;
extends 'SVN::Dump::Change';

has src_rev     => ( is => 'ro', isa => 'Int', required => 1 );
has src_path    => ( is => 'ro', isa => 'Str', required => 1 );

has src_container => (
	is => 'ro',
	isa => 'SVN::Dump::Entity',
	required => 1
);

sub is_from_container {
	my $self = shift;
	return 1 if $self->src_path() eq $self->src_container()->path();
	return;
}

has rel_src_path => (
	is => 'ro',
	isa => 'Str',
	lazy => 1,
	default => sub {
		my $self = shift;
		my $path = $self->src_path();
		my $container_path = $self->src_container()->path();

		die unless $path =~ s/^\Q$container_path\E(\/|$)/trunk$1/;
		return $path;
	},
);

1;
