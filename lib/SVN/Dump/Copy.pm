package SVN::Dump::Copy;

use Moose;

has src_revision  => ( is => 'ro', isa => 'Int', required => 1 );
has src_path      => ( is => 'ro', isa => 'Str', required => 1 );
has src_container => (
	is        => 'ro',
	isa       => 'SVN::Dump::Entity',
	required  => 1
);
has dst_revision  => ( is => 'ro', isa => 'Int', required => 1 );
has dst_path      => ( is => 'ro', isa => 'Str', required => 1 );
has dst_container => (
	is        => 'ro',
	isa       => 'SVN::Dump::Entity',
	required  => 1
);

sub debug {
	my ($self, $template) = @_;
	return sprintf(
		$template,
		sprintf(
			"copy from %s \@%s to %s \@%s",
			$self->src_path(), $self->src_revision(),
			$self->dst_path(), $self->dst_revision(),
		)
	)
}

sub is_src_container {
	my $self = shift;
	return 1 if $self->src_path() eq $self->src_container()->path();
	return;
}

sub is_dst_container {
	my $self = shift;
	return 1 if $self->dst_path() eq $self->dst_container()->path();
	return;
}

has rel_src_path => (
	is      => 'ro',
	isa     => 'Str',
	lazy    => 1,
	default => sub {
		my $self = shift;
		my $path = $self->src_path();

		#return $path if $self->is_src_container();

		my $container_path = $self->src_container()->path();

		die unless $path =~ s/^\Q$container_path\E(\/|$)/trunk$1/;
		return $path;
	},
);

has rel_dst_path => (
	is      => 'ro',
	isa     => 'Str',
	lazy    => 1,
	default => sub {
		my $self = shift;
		my $path = $self->dst_path();

		#return $path if $self->is_dst_container();

		my $container_path = $self->dst_container()->path();

		die unless $path =~ s/^\Q$container_path\E(\/|$)/trunk$1/;
		return $path;
	},
);

1;
