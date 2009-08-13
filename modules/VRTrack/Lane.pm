package VRTrack::Lane; 
=head1 NAME

VRTrack::Lane - Sequence Tracking Lane object

=head1 SYNOPSIS
    my $lane= VRTrack::Lane->new($dbh, $lane_id);

    my $id = $lane->id();
    my $status = $lane->status();

=head1 DESCRIPTION

An object describing the tracked properties of a lane.

=head1 CONTACT

jws@sanger.ac.uk

=head1 METHODS

=cut

use strict;
use warnings;
no warnings 'uninitialized';
use constant DBI_DUPLICATE => '1062';
use VRTrack::Mapstats;
use VRTrack::File;
use VRTrack::Submission;
use VRTrack::Utils;

###############################################################################
# Class methods
###############################################################################

=head2 new

  Arg [1]    : database handle to seqtracking database
  Arg [2]    : lane id
  Example    : my $lane= VRTrack::Lane->new($dbh, $id)
  Description: Returns Lane object by lane_id
  Returntype : VRTrack::Lane object

=cut

sub new {
    my ($class,$dbh, $id) = @_;
    die "Need to call with a db handle and id" unless ($dbh && $id);
    my $self = {};
    bless ($self, $class);
    $self->{_dbh} = $dbh;

    my $sql = qq[select lane_id, library_id, name, hierarchy_name, acc, readlen, paired, recalibrated, raw_reads, raw_bases, qc_status, submission_id, withdrawn, changed, latest from lane where lane_id = ? and latest = true];
    my $sth = $self->{_dbh}->prepare($sql);

    if ($sth->execute($id)){
        my $data = $sth->fetchrow_hashref;
	unless ($data){
	    return undef;
	}
	$self->id($data->{'lane_id'});
	$self->library_id($data->{'library_id'});
	$self->name($data->{'name'});
	$self->hierarchy_name($data->{'hierarchy_name'});
	$self->acc($data->{'acc'});
	$self->read_len($data->{'readlen'});
	$self->is_paired($data->{'paired'});
	$self->is_recalibrated($data->{'recalibrated'});
	$self->raw_reads($data->{'raw_reads'});
	$self->raw_bases($data->{'raw_bases'});
	$self->qc_status($data->{'qc_status'});
	$self->submission_id($data->{'submission_id'});
	$self->is_withdrawn($data->{'withdrawn'});
        $self->changed($data->{'changed'});
	$self->dirty(0);    # unset the dirty flag
    }
    else{
	die(sprintf('Cannot retrieve lane: %s', $DBI::errstr));
    }

    return $self;
}


=head2 new_by_field_value

  Arg [1]    : database handle to seqtracking database
  Arg [2]    : field name
  Arg [3]    : field value
  Example    : my $lane = VRTrack::Lane->new_by_field_value($dbh, 'name',$name)
  Description: Class method. Returns latest Lane object by field name and value.  If no such value is in the database, returns undef.
               Dies if there is more than one matching record.
  Returntype : VRTrack::Lane object

=cut

sub new_by_field_value {
    my ($class,$dbh, $field, $value) = @_;
    die "Need to call with a db handle, field name, field value" unless ($dbh && $field && defined $value);
    
    # check field exists
    my $colnames = $dbh->selectcol_arrayref(q[select column_name from information_schema.columns where table_name='lane']);
    my %cols = map { $_ => 1 } @$colnames;
    unless (exists($cols{lc($field)})){
        die "No such column $field in lane table\n";
    }

    # retrieve lane_id
    my $sql = qq[select lane_id from lane where $field = ? and latest = true];
    my $sth = $dbh->prepare($sql);
    my $id;
    if ($sth->execute($value)){
        my $data = $sth->fetchall_arrayref({}); #return array of hashes
        unless (@$data){
            return undef;
        }
        if (scalar @$data > 1){
            die "$field = $value is not a unique identifier for lane\n";
        }
        $id = $data->[0]{'lane_id'};
    }
    else{
        die(sprintf('Cannot retrieve lane by %s = %s: %s', ($field,$value,$DBI::errstr)));
    }
    return $class->new($dbh, $id);
}


=head2 new_by_name

  Arg [1]    : database handle to seqtracking database
  Arg [2]    : lane name
  Example    : my $lane = VRTrack::Lane->new_by_name($dbh, $name)
  Description: Class method. Returns latest Lane object by name.  If no such name is in the database, returns undef.  Dies if multiple names match.
  Returntype : VRTrack::Lane object

=cut

sub new_by_name {
    my ($class,$dbh, $name) = @_;
    die "Need to call with a db handle, name" unless ($dbh && $name);
    return $class->new_by_field_value($dbh, 'name',$name);
}


=head2 new_by_hierarchy_name

  Arg [1]    : database handle to seqtracking database
  Arg [2]    : lane hierarchy_name
  Example    : my $lane = VRTrack::Lane->new_by_hierarchy_name($dbh, $hierarchy_name)
  Description: Class method. Returns latest Lane object by hierarchy_name.  If no such hierarchy_name is in the database, returns undef.  Dies if multiple hierarchy_names match.
  Returntype : VRTrack::Lane object

=cut

sub new_by_hierarchy_name {
    my ($class,$dbh, $hierarchy_name) = @_;
    die "Need to call with a db handle, hierarchy_name" unless ($dbh && $hierarchy_name);
    return $class->new_by_field_value($dbh, 'hierarchy_name',$hierarchy_name);
}


=head2 create

  Arg [1]    : database handle to seqtracking database
  Arg [2]    : lane name
  Example    : my $lane = VRTrack::Lane->create($dbh, $name)
  Description: Class method.  Creates new Lane object in the database.
  Returntype : VRTrack::Lane object

=cut

sub create {
    my ($class,$dbh, $name) = @_;
    die "Need to call with a db handle and name" unless ($dbh && $name);

    my $hierarchy_name = $name;
    $hierarchy_name =~ s/\W+/_/g;

    # prevent adding a lane with an existing name
    if ($class->is_name_in_database($dbh, $name, $hierarchy_name)){
        die "Already a lane by name $name/$hierarchy_name";
    }

    $dbh->do (qq[LOCK TABLE lane WRITE]);
    my $sql = qq[select max(lane_id) as id from lane];
    my $sth = $dbh->prepare($sql);
    my $next_id;
    if ($sth->execute()){
	my $data = $sth->fetchrow_hashref;
	unless ($data){
            $dbh->do (qq[UNLOCK TABLES]);
            die( sprintf("Can't retrieve next lane id: %s", $DBI::errstr));
	}
        $next_id = $data->{'id'};
        $next_id++;
    }
    else{
	die(sprintf("Can't retrieve next lane id: %s", $DBI::errstr));
    }

    $sql = qq[INSERT INTO lane (lane_id, name, hierarchy_name, changed, latest) 
                 VALUES (?,?,?,now(),true)];

    $sth = $dbh->prepare($sql);
    unless ($sth->execute( $next_id, $name,$hierarchy_name )) {
        $dbh->do (qq[UNLOCK TABLES]);
        die( sprintf('DB load insert failed: %s %s', $next_id, $DBI::errstr));
    }

    $dbh->do (qq[UNLOCK TABLES]);

    return $class->new($dbh, $next_id);
}


=head2 is_name_in_database

  Arg [1]    : lane name
  Arg [2]    : hierarchy name
  Example    : if(VRTrack::Lane->is_name_in_database($dbh, $name, $hname)
  Description: Class method. Checks to see if a name or hierarchy name is already used in the lane table.
  Returntype : boolean

=cut

sub is_name_in_database {
    my ($class, $dbh, $name, $hname) = @_;
    die "Need to call with a db handle, name, hierarchy name" unless ($dbh && $name && $hname);
    my $sql = qq[select lane_id from lane where latest=true and (name = ? or hierarchy_name = ?) ];
    my $sth = $dbh->prepare($sql);

    my $already_used = 0;
    if ($sth->execute($name,$hname)){
        my $data = $sth->fetchrow_hashref;
        if ($data){
            $already_used = 1;
        }
    }
    else{
        die(sprintf('Cannot retrieve lane by $name: %s', $DBI::errstr));
    }
    return $already_used;
}


###############################################################################
# Object methods
###############################################################################

=head2 dirty

  Arg [1]    : boolean for dirty status
  Example    : $lane->dirty(1);
  Description: Get/Set for lane properties having been altered.
  Returntype : boolean

=cut

sub dirty {
    my ($self,$dirty) = @_;
    if (defined $dirty){
	$self->{_dirty} = $dirty ? 1 : 0;
    }
    return $self->{_dirty};
}


=head2 id

  Arg [1]    : id (optional)
  Example    : my $id = $lane->id();
	       $lane->id(104);
  Description: Get/Set for internal db ID of a lane
  Returntype : integer

=cut

sub id {
    my ($self,$id) = @_;
    if (defined $id and $id != $self->{'id'}){
	$self->{'id'} = $id;
	$self->dirty(1);
    }
    return $self->{'id'};
}


=head2 library_id

  Arg [1]    : library_id (optional)
  Example    : my $library_id = $lane->library_id();
	       $lane->library_id('104');
  Description: Get/Set for ID of a lane
  Returntype : Internal ID

=cut

sub library_id {
    my ($self,$library_id) = @_;
    if (defined $library_id and $library_id != $self->{'library_id'}){
	$self->{'library_id'} = $library_id;
	$self->dirty(1);
    }
    return $self->{'library_id'};
}


=head2 hierarchy_name

  Arg [1]    : directory name (optional)
  Example    : my $hname = $lane->hierarchy_name();
  Description: Get/set lane hierarchy name.  This is the directory name (without path) that the lane will be named in a file hierarchy.
  Returntype : string

=cut

sub hierarchy_name {
    my ($self,$name) = @_;
    if (defined $name and $name ne $self->{'hierarchy_name'}){
        $self->{'hierarchy_name'} = $name;
	$self->dirty(1);
    }
    return $self->{'hierarchy_name'};
}


=head2 name

  Arg [1]    : name (optional)
  Example    : my $name = $lane->name();
	       $lane->name('1044_1');
  Description: Get/Set for name of a lane
  Returntype : string

=cut

sub name {
    my ($self,$name) = @_;
    if (defined $name and $name ne $self->{'name'}){
	$self->{'name'} = $name;
	$self->dirty(1);
    }
    return $self->{'name'};
}


=head2 acc

  Arg [1]    : acc (optional)
  Example    : my $acc = $lane->acc();
	       $lane->acc('ERR0000538');
  Description: Get/Set for [ES]RA/DCC accession
  Returntype : string

=cut

sub acc {
    my ($self,$acc) = @_;
    if (defined $acc and $acc ne $self->{'acc'}){
	$self->{'acc'} = $acc;
	$self->dirty(1);
    }
    return $self->{'acc'};
}



=head2 read_len

  Arg [1]    : read_len (optional)
  Example    : my $read_len = $lane->read_len();
	       $lane->read_len(54);
  Description: Get/Set for lane read_len
  Returntype : integer

=cut

sub read_len {
    my ($self,$read_len) = @_;
    if (defined $read_len and $read_len != $self->{'read_len'}){
	$self->{'read_len'} = $read_len;
	$self->dirty(1);
    }
    return $self->{'read_len'};
}


=head2 is_paired

  Arg [1]    : boolean for is_paired status
  Example    : $lane->is_paired(1);
  Description: Get/Set for lane being paired-end sequencing
  Returntype : boolean

=cut

sub is_paired {
    my ($self,$is_paired) = @_;
    if (defined $is_paired){
	$self->{is_paired} = $is_paired ? 1 : 0;
    }
    return $self->{is_paired};
}


=head2 is_recalibrated

  Arg [1]    : boolean for is_recalibrated status
  Example    : $lane->is_recalibrated(1);
  Description: Get/Set for whether lane has been recalibrated or not
  Returntype : boolean

=cut

sub is_recalibrated {
    my ($self,$is_recalibrated) = @_;
    if (defined $is_recalibrated){
	$self->{is_recalibrated} = $is_recalibrated ? 1 : 0;
    }
    return $self->{is_recalibrated};
}


=head2 is_withdrawn

  Arg [1]    : boolean for is_withdrawn status
  Example    : $lane->is_withdrawn(1);
  Description: Get/Set for whether lane has been withdrawn or not
  Returntype : boolean

=cut

sub is_withdrawn {
    my ($self,$is_withdrawn) = @_;
    if (defined $is_withdrawn){
	$self->{is_withdrawn} = $is_withdrawn ? 1 : 0;
    }
    return $self->{is_withdrawn};
}


=head2 raw_reads

  Arg [1]    : raw_reads (optional)
  Example    : my $raw_reads = $lane->raw_reads();
	       $lane->raw_reads(100000);
  Description: Get/Set for number of raw reads in lane
  Returntype : integer

=cut

sub raw_reads {
    my ($self,$raw_reads) = @_;
    if (defined $raw_reads and $raw_reads != $self->{'raw_reads'}){
	$self->{'raw_reads'} = $raw_reads;
	$self->dirty(1);
    }
    return $self->{'raw_reads'};
}


=head2 raw_bases

  Arg [1]    : raw_bases (optional)
  Example    : my $raw_bases = $lane->raw_bases();
	       $lane->raw_bases(100000);
  Description: Get/Set for number of raw reads in lane
  Returntype : integer

=cut

sub raw_bases {
    my ($self,$raw_bases) = @_;
    if (defined $raw_bases and $raw_bases != $self->{'raw_bases'}){
	$self->{'raw_bases'} = $raw_bases;
	$self->dirty(1);
    }
    return $self->{'raw_bases'};
}


=head2 submission_id

  Arg [1]    : submission_id (optional)
  Example    : my $submission_id = $lane->submission_id();
	       $lane->submission_id(3);
  Description: Get/Set for submission internal id
  Returntype : integer

=cut

sub submission_id {
    my ($self,$submission_id) = @_;
    if (defined $submission_id and $submission_id != $self->{'submission_id'}){
	$self->{'submission_id'} = $submission_id;
	$self->dirty(1);
    }
    return $self->{'submission_id'};
}


=head2 submission

  Arg [1]    : submission name (optional)
  Example    : my $submission = $lane->submission();
               $lane->submission('g1k-sc-20080812-2');
  Description: Get/Set for sample submission.  Lazy-loads submission object from $self->submission_id.  If a submission name is supplied, then submission_id is set to the corresponding submission in the database.  If no such submission exists, returns undef.  Use add_submission to add a submission in this case.
  Returntype : VRTrack::Submission object

=cut

sub submission {
    my ($self,$submission) = @_;
    if ($submission){
        # get existing submission by name
        my $obj = $self->get_submission_by_name($submission);
        if ($obj){
            $self->{'submission'} = $obj;
            $self->{'submission_id'} = $obj->id;
            $self->dirty(1);
        }
        else {
            # warn "No such submission in the database";
            return undef; # explicitly return nothing.
        }
    }
    elsif ($self->{'submission'}){
        # already got a submission object.  We'll return it at the end.
    }
    else {  # lazy-load submission from database
        if ($self->submission_id){
            my $obj = VRTrack::Submission->new($self->{_dbh},$self->submission_id);
            $self->{'submission'} = $obj;
        }
    }
    return $self->{'submission'};
}


=head2 add_submission

  Arg [1]    : submission name
  Example    : my $sub = $lane->add_submission('NA19820');
  Description: create a new submission, and if successful, return the object
  Returntype : VRTrack::Library object

=cut

sub add_submission {
    my ($self, $name) = @_;

    my $obj = $self->get_submission_by_name($name);
    if ($obj){
        warn "Submission $name is already present in the database\n";
        return undef;
    }
    else {
        $obj = VRTrack::Submission->create($self->{_dbh}, $name);
        # populate caches
        $self->{'submission_id'} = $obj->id;
        $self->{'submission'} = $obj;
        $self->dirty(1);
    }
    return $self->{'submission'};
}


=head2 get_submission_by_name

  Arg [1]    : submission_name
  Example    : my $sub = $lane->get_submission_by_name('NA19820');
  Description: Retrieve a VRTrack::Submission object by name
               Note that the submission object retrieved is not necessarily
               attached to this Lane.
  Returntype : VRTrack::Submission object

=cut

sub get_submission_by_name {
    my ($self,$name) = @_;
    return VRTrack::Submission->new_by_name($self->{_dbh}, $name);
}


=head2 qc_status

  Arg [1]    : qc_status (optional)
  Example    : my $qc_status = $lane->qc_status();
	       $lane->qc_status('104');
  Description: Get/Set for lane qc_status
  Returntype : string

=cut

sub qc_status {
    my ($self,$qc_status) = @_;
    if (defined $qc_status and $qc_status ne $self->{'qc_status'}){
        my %allowed = map {$_ => 1} @{VRTrack::Utils::list_enum_vals($self->{_dbh},'lane','qc_status')};
        unless ($allowed{lc($qc_status)}){
            die "'$qc_status' is not a defined qc_status";
        }
	$self->{'qc_status'} = $qc_status;
	$self->dirty(1);
    }
    return $self->{'qc_status'};
}


=head2 changed

  Arg [1]    : changed (optional)
  Example    : my $changed = $lane->changed();
               $lane->changed('20080810123000');
  Description: Get/Set for lane changed
  Returntype : string

=cut

sub changed {
    my ($self,$changed) = @_;
    if (defined $changed and $changed ne $self->{'changed'}){
	$self->{'changed'} = $changed;
	$self->dirty(1);
    }
    return $self->{'changed'};
}


=head2 latest_mapping

  Arg [1]    : None
  Example    : my $latest_mapping = $lane->latest_mapping();
  Description: Returns single most recent mapping on this lane.
  Returntype : VRTrack::Mapstat object

=cut

sub latest_mapping {
    my ($self) = @_;
    my @sorted_mappings = sort {$a->changed cmp $b->changed} @{$self->mappings};
    return $sorted_mappings[-1];
}


=head2 mappings

  Arg [1]    : None
  Example    : my $mappings = $lane->mappings();
  Description: Returns a ref to an array of the mappings that are associated with this lane.
  Returntype : ref to array of VRTrack::Mapstats objects

=cut

sub mappings {
    my ($self) = @_;
    unless ($self->{'mappings'}){
	my @mappings;
    	foreach my $id (@{$self->mapping_ids()}){
	    my $obj = VRTrack::Mapstats->new($self->{_dbh},$id);
	    push @mappings, $obj;
	}
	$self->{'mappings'} = \@mappings;
    }

    return $self->{'mappings'};
}


=head2 mapping_ids

  Arg [1]    : None
  Example    : my $mapping_ids = $lane->mapping_ids();
  Description: Returns a ref to an array of the ids of the mappings that are associated with this lane
  Returntype : ref to array of mapping ids

=cut

sub mapping_ids {
    my ($self) = @_;
    unless ($self->{'mapping_ids'}){
	my $sql = qq[select distinct(mapstats_id) from mapstats where lane_id=? and latest=true];
	my @files;
	my $sth = $self->{_dbh}->prepare($sql);

	if ($sth->execute($self->id)){
	    foreach(@{$sth->fetchall_arrayref()}){
		push @files, $_->[0];
	    }
	}
	else{
	    die(sprintf('Cannot retrieve files: %s', $DBI::errstr));
	}

	$self->{'mapping_ids'} = \@files;
    }
 
    return $self->{'mapping_ids'};
}


=head2 files

  Arg [1]    : None
  Example    : my $files = $lane->files();
  Description: Returns a ref to an array of the file objects that are associated with this lane.
  Returntype : ref to array of VRTrack::File objects

=cut

sub files {
    my ($self) = @_;
    unless ($self->{'files'}){
	my @files;
    	foreach my $id (@{$self->file_ids()}){
	    my $obj = VRTrack::File->new($self->{_dbh},$id);
	    push @files, $obj;
	}
	$self->{'files'} = \@files;
    }

    return $self->{'files'};
}


=head2 file_ids

  Arg [1]    : None
  Example    : my $file_ids = $lane->file_ids();
  Description: Returns a ref to an array of the file ids that are associated with this lane
  Returntype : ref to array of file ids

=cut

sub file_ids {
    my ($self) = @_;
    unless ($self->{'file_ids'}){
	my $sql = qq[select file_id from file where lane_id=? and latest = true];
	my @files;
	my $sth = $self->{_dbh}->prepare($sql);

	if ($sth->execute($self->id)){
	    foreach(@{$sth->fetchall_arrayref()}){
		push @files, $_->[0];
	    }
	}
	else{
	    die(sprintf('Cannot retrieve files: %s', $DBI::errstr));
	}

	$self->{'file_ids'} = \@files;
    }
 
    return $self->{'file_ids'};
}


=head2 add_file

  Arg [1]    : file name
  Example    : my $newfile = $lib->add_file('1_s_1.fastq');
  Description: create a new file, and if successful, return the object
  Returntype : VRTrack::File object

=cut

sub add_file {
    my ($self, $name) = @_;
    $name or die "Must call add_file with file name";

    # File names should not be added twice - this can't be caught by the
    # database, as we expect there will be multiple rows for the same file.
    my $obj = $self->get_file_by_name($name);
    if ($obj){
        warn "File $name is already present in the database\n";
        return undef;
    }
    $obj = VRTrack::File->create($self->{_dbh}, $name);
    if ($obj){
        $obj->lane_id($self->id);
        $obj->update;
    }
    # clear caches
    delete $self->{'file_ids'};
    delete $self->{'files'};

    return $obj;

}


=head2 add_mapping

  Arg [1]    : none
  Example    : my $newmapping = $lib->add_mapping();
  Description: create a new mapping, and if successful, return the object
  Returntype : VRTrack::Mapstats object

=cut

sub add_mapping {
    my ($self) = @_;
    my $obj = VRTrack::Mapstats->create($self->{_dbh}, $self->id);
    # clear caches
    delete $self->{'mapping_ids'};
    delete $self->{'mappings'};
    return $obj;
}


=head2 get_file_by_name

  Arg [1]    : file name
  Example    : my $file = $lane->get_file_by_name('My file');
  Description: retrieve file object on this lane by name
  Returntype : VRTrack::File object

=cut

sub get_file_by_name {
    my ($self, $name) = @_;
    #my $obj = VRTrack::File->new_by_name($self->{_dbh},$name);
    my @match = grep {$_->name eq $name} @{$self->files};
    if (scalar @match > 1){ # shouldn't happen
        die "More than one matching file with name $name";
    }
    my $obj;
    if (@match){
        $obj = $match[0];
    }

    return $obj;
}


=head2 get_file_by_id

  Arg [1]    : internal file id
  Example    : my $file = $lib->get_file_by_id(47);
  Description: retrieve file object by internal db file id
  Returntype : VRTrack::File object

=cut

sub get_file_by_id {
    my ($self, $id) = @_;
    my $obj = VRTrack::File->new($self->{_dbh},$id);
    return $obj;
}


=head2 update

  Arg [1]    : None
  Example    : $lane->update();
  Description: Update a lane whose properties you have changed.  If properties haven't changed (i.e. dirty flag is unset) do nothing.  
	       Changes the changed datestamp to now() on the mysql server (i.e. you don't have to set changed yourself, and indeed if you do, it will be overridden).
               Unsets dirty flag on success.
  Returntype : 1 if successful, otherwise undef.

=cut

sub update {
    my ($self) = @_;
    my $success = undef;
    if ($self->dirty){
	my $dbh = $self->{_dbh};
	my $save_re = $dbh->{RaiseError};
	my $save_pe = $dbh->{PrintError};
	my $save_ac = $dbh->{AutoCommit};
	$dbh->{RaiseError} = 1; # raise exception if an error occurs
	$dbh->{PrintError} = 0; # don't print an error message
	$dbh->{AutoCommit} = 0; # disable auto-commit (starts transaction)

	eval {
	    # Need to unset 'latest' flag on current latest lane and add
	    # the new lane details with the latest flag set
	    my $updsql = qq[UPDATE lane SET latest=false WHERE lane_id = ? and latest=true];
	    
	    my $addsql = qq[INSERT INTO lane (lane_id, library_id, name, hierarchy_name, acc, readlen, paired, recalibrated, raw_reads, raw_bases, qc_status, submission_id, withdrawn, changed, latest) 
			    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,now(),true)];
	    $dbh->do ($updsql, undef,$self->id);
	    $dbh->do ($addsql, undef,$self->id, $self->library_id, $self->name, $self->hierarchy_name, $self->acc, $self->read_len, $self->is_paired, $self->is_recalibrated, $self->raw_reads, $self->raw_bases, $self->qc_status, $self->submission_id, $self->is_withdrawn);
	    $dbh->commit ( );
	};

	if ($@) {
	    warn "Transaction failed, rolling back. Error was:\n$@\n";
	    # roll back within eval to prevent rollback
	    # failure from terminating the script
	    eval { $dbh->rollback ( ); };
	}
	else {
	    $success = 1;
	}

	# restore attributes to original state
	$dbh->{AutoCommit} = $save_ac;
	$dbh->{PrintError} = $save_pe;
	$dbh->{RaiseError} = $save_re;

    }
    if ($success){
        $self->dirty(0);
    }

    return $success;
}

1;
