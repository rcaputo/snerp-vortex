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
			"copy from %s r%s (%s) to %s r%s (%s)",
			$self->src_path(), $self->src_revision(),
			$self->src_container->debug("%s"),
			$self->dst_path(), $self->dst_revision(),
			$self->dst_container->debug("%s"),
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
		my $base_path = $self->src_container()->base_path();

		if (length $container_path) {
			die "path $path is not within container $container_path" unless (
				$path =~ s!^\Q$container_path\E(/|$)!./$base_path$1!
			);
		}
		else {
			substr($path, 0, 0) = "./$base_path/";
		}

		$path =~ tr[/][/]s;
		$path =~ s!/+$!!;

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
		my $base_path = $self->dst_container()->base_path();

		if (length $container_path) {
			die "path $path is not within container $container_path" unless (
				$path =~ s!^\Q$container_path\E(/|$)!./$base_path$1!
			);
		}
		else {
			substr($path, 0, 0) = "./$base_path/";
		}

		$path =~ tr[/][/]s;
		$path =~ s!/+$!!;

		return $path;
	},
);

1;
