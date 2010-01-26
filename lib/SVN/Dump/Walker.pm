package SVN::Dump::Walker;

# Base class for higher-level objects that process SVN::Dump streams.
# Does some fundamental handling of SVN::Dump events, then provides
# slightly higher level events to callbacks.

# TODO - Basically done.  Think twice if you think it requires
# modification.

use Moose;
use SVN::Dump;

has svn_dump_filename => (
	is        => 'ro',
	isa       => 'Str',
	required  => 1,
);

has current_revision => (
	is      => 'rw',
	isa     => 'Int',
	reader  => 'get_current_revision',
	writer  => 'set_current_revision',
);

has svn_dump => (
	is      => 'ro',
	isa     => 'SVN::Dump',
	lazy    => 1,
	default => sub {
		my $self = shift;
		return SVN::Dump->new(
			{ file => $self->svn_dump_filename() },
		);
	},
);

# ($self, $revision)
sub on_revision_done { undef }

# ($self, $revision, $author, $date, $log_message)
sub on_revision { undef }

# ($self, $revision, $path, $kind, $data)
sub on_node_add { undef }

# ($self, $revision, $path, $kind, $data)
sub on_node_change { undef }

# ($self, $revision, $path)
sub on_node_delete { undef }

# ($self, $revision, $path, $kind, $from_rev, $from_path, $data)
sub on_node_copy { undef }

# ($self)
sub on_walk_begin { undef }

# ($self)
sub on_walk_done { undef }

sub walk {
	my $self = shift;

	my $record;
	RECORD: while (
		$record = (
			$record && $record->get_included_record()
		) || $self->svn_dump()->next_record()
	) {
		my $type = $record->type();

		# Unsupported for now.  Does anyone need these?
		next RECORD if $type eq "format";
		next RECORD if $type eq "uuid";

		my $header = $record->get_headers_block();

		if ($type eq "revision") {
			$self->on_revision_done($self->get_current_revision()) if (
				defined $self->get_current_revision()
			);

			$self->set_current_revision($header->{'Revision-number'});

			my $author = $record->get_property("svn:author");
			$author = "svn" unless defined($author) and length($author);

			$self->on_revision(
				$self->get_current_revision(),
				$author,
				$record->get_property("svn:date"),
				$record->get_property("svn:log"),
			);
			next RECORD;
		}

		die "unexpected svn dump type '$type'" unless $type eq "node";

		my $action = $header->get('Node-action');

		# Can't copy a deletion, and deletion knows no kind.
		if ($action eq "delete") {
			my $path = $header->get('Node-path');
			$self->on_node_delete($self->get_current_revision(), $path);
			next RECORD;
		}

		my $text = $record->get_text_block();

		# Add can be plain or involve a copy operation.
		if ($action eq "add") {
			my $copy_from_rev  = $header->get('Node-copyfrom-rev');
			my $copy_from_path = $header->get('Node-copyfrom-path');

			if (defined $copy_from_rev) {
				$self->on_node_copy(
					$self->get_current_revision(),
					$header->get('Node-path'),
					$header->get('Node-kind'),
					$copy_from_rev,
					$copy_from_path,
					($text ? $text->get() : undef),
				);
				next RECORD;
			}

			$self->on_node_add(
				$self->get_current_revision(),
				$header->get('Node-path'),
				$header->get('Node-kind'),
				($text ? $text->get() : undef),
			);
			next RECORD;
		}

		if ($action eq "change") {
			$self->on_node_change(
				$self->get_current_revision(),
				$header->get('Node-path'),
				$header->get('Node-kind'),
				($text ? $text->get() : undef),
			);
			next RECORD;
		}

		die "strange action '$action'";
	}

	$self->on_revision_done($self->get_current_revision()) if (
		$self->get_current_revision()
	);

	$self->on_walk_done();

	# For chained methods.
	return $self;
}

1;
