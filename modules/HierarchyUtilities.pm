package HierarchyUtilities;
use strict;
use Carp;
use File::Basename;
use File::Spec; 
use File::Copy;
use Cwd;

use AssemblyTools;

=pod

=head1 NAME

=head1 SYNOPSIS

function to import the DCC tab index files into the hierarchy

=head1 ARGUMENTS

=head1 DESCRPTION

=head1 AUTHOR

Thomas Keane, I<tk2@sanger.ac.uk>

=cut

sub importExternalData
{
	croak "Usage: importExternalData populations/samples_csv DCC_index hierarchy_parent_directory mapping_hierarchy_directory fastq_directory" unless @_ == 5;
	
	my $pop_csv = shift;
	my $index_file = shift;
	my $data_hierarchy_dir = shift;
	my $mapping_hierarchy_dir = shift;
	my $fastqDir = shift;
	
	croak "Cant find populations_csv file" unless -f $pop_csv;
	croak "Cant find index file" unless -f $index_file;
	croak "Cant find fastq directory" unless -d $fastqDir;
	croak "Cant find data hierarchy parent directory" unless -d $data_hierarchy_dir;
	croak "Cant find mapping hierarchy parent directory" unless -d $mapping_hierarchy_dir;
	
	my %study_vs_id = (
			28911   => 'LowCov',  # pilot 1
		    28919   => 'Trio',    # pilot 2
		    28917   => 'Exon',    # pilot 3
		    'SRP000031'   => 'LowCov',    # pilot 1
		    'SRP000032'   => 'Trio',    # pilot 2
		    'SRP000033'   => 'Exon',    # pilot 3
		    'Pilot1'   => 'LowCov',    # pilot 1
		    'Pilot2'   => 'LowCov',    # pilot 1
		    'Pilot3'   => 'LowCov',    # pilot 1
		    );
	
	#read in the project spreadsheet with individuals
	open( PCSV, $pop_csv ) or die "Failed to open population csv sheet: $!\n";
	my %populations;
	while( <PCSV> )
	{
		chomp;
		next unless length( $_ ) > 0 && $_ !~ /^\s+$/ && $_ !~ /^,+$/;
		
		my @s = split( /,/, $_ );
		$populations{ $s[ 1 ] } = $s[ 5 ];
	}
	close( PCSV );
	
	my %exp_read0;
	my %exp_read1;
	my %exp_read2;
	my %data_exp_path; #directory within data hierarchy
	my %mapping_exp_path; #mapping directory
	
	my %srrCount;
	
	open( LCSV, $index_file ) or die "Failed to open lane index file: $!\n";
	while( <LCSV> )
	{
		chomp;
		my $original = $_;
		
		next if( $_ =~ /^\s+$/ || length( $_ ) == 0 || $_ =~ /^FASTQ_FILE/ );
		
		my @info = split( /\t/, $_ );
		
		if( $info[ 18 ] ne "PAIRED" && $info[ 18 ] ne "SINGLE" )
		{
			print "Skipping line: $_\n";
			my $i = 0;
			foreach( @info )
			{
				print $i."->x".$info[ $i ]."x\n";
				$i ++;
			}
			exit;
			next;
		}
		
		croak "Cant find study for lane ID: $info[ 3 ]\n" if( ! defined $study_vs_id{ $info[ 3 ] } );
		croak "Cant find population for lane ID: $info[ 9 ]\n" if( ! defined $populations{ $info[ 9 ] } );
		
		#check SRR is unique
		if( defined( $srrCount{ $info[ 2 ] } ) )
		{
			if( ( $srrCount{ $info[ 2 ] } == 3 && $info[ 12 ] =~ /.*[roche|454].*/ ) || $info[ 19 ] eq 'SINGLE' )
			{
				print "ERROR: Non-unique SRR found: $info[ 2 ]\n";
				exit;
			}
			else
			{
				$srrCount{ $info[ 2 ] } ++;
			}
		}
		else
		{
			$srrCount{ $info[ 2 ] } = 1;
		}
		
		#unpaired
		if( $info[ 18 ] eq 'SINGLE' || ( $info[ 18 ] eq 'PAIRED' && length( $info[ 19 ] ) == 0 ) )
		{
			$exp_read0{ $info[ 2 ] } = basename( $info[ 0 ] );
		}
		elsif( $info[ 18 ] eq 'PAIRED' )
		{
			if( ! defined( $exp_read1{ $info[ 2 ] } ) )
			{
				$exp_read1{ $info[ 2 ] } = basename( $info[ 0 ] );
			}
			else
			{
				$exp_read2{ $info[ 2 ] } = basename( $info[ 0 ] );
			}
		}
		
		my $dpath = $data_hierarchy_dir.'/'.$study_vs_id{ $info[ 3 ] }.'-'.$populations{ $info[ 9 ] }.'/'.$info[ 9 ];
		my $mpath = $mapping_hierarchy_dir.'/'.$study_vs_id{ $info[ 3 ] }.'-'.$populations{ $info[ 9 ] }.'/'.$info[ 9 ];
		
		#technology
		if( $info[ 12 ] =~ /454|roche/i )
		{
			$dpath = $dpath.'/454';
			$mpath = $mpath.'/454';
		}
		elsif( $info[ 12 ] =~ /solid/i )
		{
			$dpath = $dpath.'/SOLID';
			$mpath = $mpath.'/SOLID';
		}
		elsif( $info[ 12 ] =~ /solexa|illumina/i )
		{
			$dpath = $dpath.'/SLX';
			$mpath = $mpath.'/SLX';
		}
		else
		{
			croak "Cannot determine sequencing technology: $info[ 12 ] in\n$original\n";
		}
		$dpath .= '/'.$info[ 14 ].'/'.$info[ 2 ];
		$mpath .= '/'.$info[ 14 ].'/'.$info[ 2 ];
		
		#check that the data has not already been imported
		if( -d $dpath )
		{
			print "Already Imported: $info[ 0 ]\n";
			next;
		}
		
		$data_exp_path{ $info[ 2 ] } = $dpath;
		$mapping_exp_path{ $info[ 2 ] } = $mpath;
	}
	close( LCSV );
	
	foreach( keys( %data_exp_path ) )
	{
		#check the fastq's exist
		if( defined( $exp_read1{ $_ } ) && ! defined( $exp_read2{ $_ } ) )
		{
			#turn it into an unpaired entry
			$exp_read0{ $_ } = $exp_read1{ $_ };
			delete( $exp_read1{ $_ } );
			print "No read2 entry so making read unpaired: $exp_read0{ $_ }\n";
			
			#print "ERROR: Failed to find read2 for: $_\n";
			#next;
		}
		
		if( defined( $exp_read1{ $_ } ) && ! -f $fastqDir.'/'.$exp_read1{ $_ } )
		{
			print "WARNING: Failed on $_: Failed to read file $exp_read1{ $_ }\n";
			next;
		}
		elsif( defined( $exp_read2{ $_ } ) && ! -f $fastqDir.'/'.$exp_read2{ $_ } )
		{
			print "WARNING: Failed on $_: Failed to read file $exp_read2{ $_ }\n";
			next;
		}
		elsif( defined( $exp_read0{ $_ } ) && ! -f $fastqDir.'/'.$exp_read0{ $_ } )
		{
			print "WARNING: Failed on $_: Failed to read file $exp_read0{ $_ }\n";
			next;
		}
		
		my $pdirName = $data_exp_path{ $_ };
		my $mdirName = $mapping_exp_path{ $_ };
		
		#make the directory in the hierarchy
		if( ! -d $pdirName )
		{
			print "Making path: $pdirName\n";
			system( "mkdir -p ".$pdirName );
			if( ! -d $pdirName )
			{
				croak "ERROR: Failed to create directory: ".$pdirName."\n";
			}
			
			print "Making path: $mdirName\n";
			system( "mkdir -p ".$mdirName );
			if( ! -d $mdirName )
			{
				croak "ERROR: Failed to create directory: ".$mdirName."\n";
			}
		}
		
		#write a meta file with the read file names
		open( META, ">$pdirName/meta.info" ) or die "Cant open meta.info file in $pdirName\n";
		
		#copy the files into the directory
		if( defined( $exp_read0{ $_ } ) && ! -l $pdirName.'/'.$exp_read0{ $_ } && ! -f $pdirName.'/'.$exp_read0{ $_ } )
		{
			copy( $fastqDir.'/'.$exp_read0{ $_ }, $pdirName.'/'.$exp_read0{ $_ } ) or die "Failed to copy file: ".$exp_read0{ $_ };
			symlink( $pdirName.'/'.$exp_read0{ $_ }, $mdirName.'/'.$exp_read0{ $_ } );
			system( 'bsub -q yesterday -o /dev/null -e /dev/null "zcat '.$pdirName.'/'.$exp_read0{ $_ }.' | awk \'{print \$1}\' | /software/solexa/bin/fastqcheck > '.$pdirName.'/'.$exp_read0{ $_ }.'.fastqcheck; ln -s '.$pdirName.'/'.$exp_read0{ $_ }.'.fastqcheck '.$mdirName.'/'.$exp_read0{ $_ }.'.fastqcheck"' );
			print META "read0:".$exp_read0{ $_ }."\n";
		}
		
		if( defined( $exp_read1{ $_ } ) && ! -l $pdirName.'/'.$exp_read1{ $_ } && ! -f $pdirName.'/'.$exp_read1{ $_ } )
		{
			copy( $fastqDir.'/'.$exp_read1{ $_ }, $pdirName.'/'.$exp_read1{ $_ } ) or die "Failed to copy file: ".$exp_read1{ $_ };
			symlink( $pdirName.'/'.$exp_read1{ $_ }, $mdirName.'/'.$exp_read1{ $_ } ) or die "Failed to sym link read into mapping directory: ".$mdirName.'/'.$exp_read1{ $_ };
			system( 'bsub -q yesterday -o /dev/null -e /dev/null "zcat '.$pdirName.'/'.$exp_read1{ $_ }.' | awk \'{print \$1}\' | /software/solexa/bin/fastqcheck > '.$pdirName.'/'.$exp_read1{ $_ }.'.fastqcheck; ln -s '.$pdirName.'/'.$exp_read1{ $_ }.'.fastqcheck '.$mdirName.'/'.$exp_read1{ $_ }.'.fastqcheck"' );
			print META "read1:".$exp_read1{ $_ }."\n";
		}
		
		if( defined( $exp_read2{ $_ } ) && ! -l $pdirName.'/'.$exp_read2{ $_ } && ! -f $pdirName.'/'.$exp_read2{ $_ } )
		{
			copy( $fastqDir.'/'.$exp_read2{ $_ }, $pdirName.'/'.$exp_read2{ $_ } ) or die "Failed to copy file: ".$exp_read2{ $_ };
			symlink( $pdirName.'/'.$exp_read2{ $_ }, $mdirName.'/'.$exp_read2{ $_ } ) or die "Failed to sym link read into mapping directory: ".$mdirName.'/'.$exp_read2{ $_ };
			system( 'bsub -q yesterday -o /dev/null -e /dev/null "zcat '.$pdirName.'/'.$exp_read2{ $_ }.' | awk \'{print \$1}\' | /software/solexa/bin/fastqcheck > '.$pdirName.'/'.$exp_read2{ $_ }.'.fastqcheck; ln -s '.$pdirName.'/'.$exp_read2{ $_ }.'.fastqcheck '.$mdirName.'/'.$exp_read2{ $_ }.'.fastqcheck"' );
			print META "read2:".$exp_read2{ $_ }."\n";
		}
		
		close( META );
		
		symlink( $pdirName.'/meta.info', $mdirName.'/meta.info' );
	}
}

#for checking the NPG for new sequence and importing it into the hierarchy
#requires a text file with 1 project name per line
#writes a meta.info file in each lane directory
my $DFIND = '/software/solexa/bin/dfind';
my $MPSA_DOWNLOAD = '/software/solexa/bin/mpsa_download';
my $FASTQ_CHECK = '/software/solexa/bin/fastqcheck';
my $LSF_QUEUE = 'normal';
my $CLIP_POINT_SCRIPT='sh ~/code/vert_reseq/user/tk2/mapping/slx/findClipPoints.sh';
sub importInternalData
{
	croak "Usage: importInternalData project_list_file data_hierarchy_parent_directory analysis_hierarchy_parent_directory" unless @_ == 3;
	my $projectFile = shift;
	my $dhierarchyDir = shift;
	my $ahierarchyDir = shift;
	
	croak "Cant find data hierarchy directory\n" unless -d $dhierarchyDir;
	croak "Cant find analysis hierarchy directory\n" unless -d $ahierarchyDir;
	croak "Cant find projects file\n" unless -f $projectFile;
	
	open( PROJS, "$projectFile" ) or die "Cannot open projects file\n";
	while( <PROJS> )
	{
		chomp;
		
		print "Updating project: $_\n";
		
		my $project = $_;
		my $project1 = $project;
		$project1 =~ s/\W+/_/g;
		
		my $projPath = $dhierarchyDir.'/'.$project1;
		mkdir $projPath unless -d $projPath;
		if( ! -d $projPath )
		{
			mkdir $projPath or die "Cannot create directory $projPath\n";
		}
		
		my $aprojPath = $ahierarchyDir.'/'.$project1;
		mkdir $aprojPath unless -d $aprojPath;
		if( ! -d $aprojPath )
		{
			mkdir $aprojPath or die "Cannot create directory $aprojPath\n";
		}
		
		my $numLibraries = 0;
		
		#dfind on the project
		open( SAMPLES, q[-|], qq[$DFIND -project="$project" -samples] ) or die "Cannot run dfind on project: $project\n";
		while( <SAMPLES> )
		{
			chomp;
			print "Updating library: $_\n";
			
			my $sample = $_; #library name
			
			#hack for G1K where sample starts with the individual
			my $individual = 1;
			if( $sample =~ /^NA\d+/ )
			{
				$individual = (split( /-/, $sample ) )[ 0 ];
			}
			
			my $sample1 = $sample;
			$sample1 =~ s/\W+/_/g;
			
			my $path = $projPath.'/'.$individual;
			if( ! -d $path )
			{
				mkdir $path or die "Cannot create directory $path\n";
			}
			$path .= '/SLX';
			if( ! -d $path )
			{
				mkdir $path or die "Cannot create directory $path\n";
			}
			$path .= '/'.$sample1;
			if( ! -d $path )
			{
				mkdir $path or die "Cannot create directory $path\n";
			}
			
			my $apath = $aprojPath.'/'.$individual;
			if( ! -d $apath )
			{
				mkdir $apath or die "Cannot create directory $apath\n";
			}
			$apath .= '/SLX';
			if( ! -d $apath )
			{
				mkdir $apath or die "Cannot create directory $apath\n";
			}
			$apath .= '/'.$sample1;
			if( ! -d $apath )
			{
				mkdir $apath or die "Cannot create directory $apath\n";
			}
			
			print "$DFIND -project=\"$project\" -sample=\"$sample\" -filetype fastq\n";
			open LANES, q[-|], qq[$DFIND -project="$project" -sample="$sample" -filetype fastq] or die "Can't get lanes for $project $sample: $!\n";
			my @dirs;
			while( <LANES> )
			{
				chomp;
				my $fastq = basename( $_ );
				
				my @s = split( /\./, $fastq );
				my @s1 = split( '_', $s[ 0 ] );
				
				my $lPath = '';
				my $alPath = '';
				if( $s1[ 1 ] eq 's' ) #hack for old read file names with s character
				{
					$lPath = $path.'/'.$s1[ 0 ].'_'.$s1[ 2 ];
					$alPath = $apath.'/'.$s1[ 0 ].'_'.$s1[ 2 ];
				}
				else
				{
					$lPath = $path.'/'.$s1[ 0 ].'_'.$s1[ 1 ];
					$alPath = $apath.'/'.$s1[ 0 ].'_'.$s1[ 1 ];
				}
				
				push( @dirs, $lPath );
				
				if( ! -d $lPath )
				{
					mkdir $lPath or die "Cannot create directory $lPath\n";
				}
				
				if( ! -d $alPath )
				{
					mkdir $alPath or die "Cannot create directory $alPath\n";
				}
				
				#check if the fastq file already exists
				my $fqPath = $lPath.'/'.$fastq;
				
				#check if the gzipped reads are already on disk
				if( $s1[ 1 ] eq 's' ) #hack for old read file names with s character
				{
					my $fastq1 = $s1[ 0 ].'_'.$s1[ 2 ].'_1.fastq.gz'; #read1 fastq
					
					if( ! -s $fqPath && ! -s $lPath.'/'.$fastq1 )
					{
						chdir( $lPath );
						
						print "Requesting file $fastq from MPSA.....\n";
						my $random = int(rand( 100000000 ));
						
						#use mpsadownload to get fastq
						my $cmd = 'bsub -J mpsa.'.$random.' -o import.o -e import.e -q '.$LSF_QUEUE.' "'.$MPSA_DOWNLOAD.' -c -f '.$fastq.' > '.$fastq.'"';
						system( $cmd );
						
						$fastq =~ /(\d+)_s_(\d+)\.fastq/;
						
						my $fastq1 = $1.'_'.$2.'_1.fastq';
						my $fastq2 = $1.'_'.$2.'_2.fastq';
						
						#write the meta.info file
						open( META, ">$alPath/meta.info" ) or die "Cannot create meta.info file\n";
						print META "read1:$fastq1.gz\n";
						print META "read2:$fastq2.gz\n";
						close( META );
						
						print "Writing meta info for: $fastq1.gz\n";
						print "Writing meta info for: $fastq2.gz\n";
						
						#work out the clip points (if any)
						$cmd = 'bsub -J clip.'.$random.' -w "done(mpsa.'.$random.')" -o import.o -e import.e -q '.$CLIP_POINT_SCRIPT.' '.$fastq1.' meta.info 1;'.$CLIP_POINT_SCRIPT.' '.$fastq2.' meta.info 2';
						system( $cmd );
						
						#create a bsub job to split the fastq
						$cmd = 'bsub -J split.'.$random.' -w "done(mpsa.'.$random.')" -o import.o -e import.e -q '.$LSF_QUEUE.' perl -w -e "use AssemblyTools;AssemblyTools::sanger2SplitFastq( \''.$fastq.'\', \''.$fastq1.'\', \''.$fastq2.'\' );"';
						system( $cmd );
						
						#run fastqcheck
						$cmd = 'bsub -J fastqcheck.'.$random.'.1 -o import.o -e import.e -q '.$LSF_QUEUE.' -w "done(split.'.$random.')" "cat '.$fastq1.' | '.$FASTQ_CHECK.'> '.$fastq1.'.gz.fastqcheck"';
						system( $cmd );
						
						$cmd = 'bsub -J fastqcheck.'.$random.'.2 -o import.o -e import.e -q '.$LSF_QUEUE.' -w "done(split.'.$random.')" "cat '.$fastq2.' | '.$FASTQ_CHECK.'> '.$fastq2.'.gz.fastqcheck; rm '.$fastq.';ln -s '.$lPath.'/'.$fastq1.'.gz '.$alPath.';ln -s '.$lPath.'/'.$fastq2.'.gz '.$alPath.'"';
						system( $cmd );
						
						#gzip the split fastq files
						$cmd = 'bsub -q '.$LSF_QUEUE.' -w "done(fastqcheck.'.$random.'.*)" -o import.o -e import.e "gzip '.$fastq1.' '.$fastq2.'"';
						system( $cmd );
						#print $cmd."\n";
						#exit;
					}
					else
					{
						print "Lane already in hierarchy: $fastq\n";
					}
				}
				elsif( ! -s $fqPath.'.gz' && ! -s $fqPath )
				{
					print "Requesting file $fastq from MPSA.....\n";
					
					chdir( $lPath );
					my $random = int(rand( 100000000 ));
					
					#use mpsadownload to get fastq
					my $cmd = 'bsub -J mpsa.'.$random.' -o import.o -e import.e -q '.$LSF_QUEUE.' "'.$MPSA_DOWNLOAD.' -c -f '.$fastq.' > '.$fastq.'"';
					system( $cmd );
					
					#run fastqcheck
					system( 'bsub -J fastqcheck.'.$random.' -w "done(mpsa.'.$random.')" -o import.o -e import.e -q '.$LSF_QUEUE.' "cat '.$fastq.' | '.$FASTQ_CHECK.' > '.$fastq.'.gz.fastqcheck; ln -s '.$lPath.'/'.$fastq.'.gz.fastqcheck '.$alPath.'"' );
					
					print "Writing meta.info for: $fastq.gz\n";
					
					#then write the meta info file
					open( META, ">>$lPath/meta.info" ) or die "Cannot create meta file in $lPath\n";
					
					#figure out if its paired or unpaired read
					if( $fastq =~ /^\d+_\d+\.fastq$/ ) #unpaired
					{
						print META "read0:$fastq.gz\n";
					}
					elsif( $fastq =~/^\d+_\d+_1.fastq$/ )
					{
						print META "read1:$fastq.gz\n";
					}
					elsif( $fastq =~/^\d+_\d+_2.fastq$/ )
					{
						print META "read2:$fastq.gz\n";
					}
					else
					{
						print "ERROR: Cant determine read information: $fastq\n";
						exit;
					}
					close( META );
					
					system( "ln -s $lPath/meta.info $alPath" );
					
					#work out the clip point (if any)
					my $readNum = 1;
					if( $fastq =~ /.*_2\.fastq/ )
					{
						$readNum = 2;
					}
					$cmd = 'bsub -J clip.'.$random.' -w "done(mpsa.'.$random.')" -o import.o -e import.e -q '.$LSF_QUEUE.' '.$CLIP_POINT_SCRIPT.' '.$fastq.' '.$alPath.'/meta.info '.$readNum;
					system( $cmd );
					
					#gzip the fastq file
					system( 'bsub -w "done(fastqcheck.'.$random.')&&done(clip.'.$random.')" -q '.$LSF_QUEUE.' -o import.o -e import.e "gzip '.$fastq.'; ln -s '.$lPath.'/'.$fastq.'.gz '.$alPath.'"' );
				}
				else
				{
					print "Fastq already in hierarchy: $fastq\n";
				}
			}
			close( LANES );
			$numLibraries ++;
		}
		close( SAMPLES );
		
		print "WARNING: No libraries found for $project\n" unless $numLibraries > 0;
	}
	close( PROJS )
}

=pod
	Function to delete lanes from a hierarchy.
	Input is a meta index file
=cut
sub deleteIndexLanes
{
	croak "Usage: deleteIndexLanes samples_csv index_file hierarchy_root_dir" unless @_ == 3;
	
	my $pop_csv = shift;
	my $index_file = shift;
	my $hierarchy_dir = shift;
	
	croak "Cant find populations_csv file" unless -f $pop_csv;
	croak "Cant find index file" unless -f $index_file;
	croak "Cant find hierarchy parent directory" unless -d $hierarchy_dir;
	
	my %study_vs_id = (28911   => 'LowCov',  # pilot 1
		    28919   => 'Trio',    # pilot 2
		    28917   => 'Exon',    # pilot 3
		    'SRP000031'   => 'LowCov',    # pilot 1
		    'SRP000032'   => 'Trio',    # pilot 2
		    'SRP000033'   => 'Exon',    # pilot 3
		    'Pilot1'   => 'LowCov',    # pilot 1
		    'Pilot2'   => 'LowCov',    # pilot 1
		    'Pilot3'   => 'LowCov',    # pilot 1
		    );
	
	#read in the project spreadsheet with individuals
	open( PCSV, $pop_csv ) or die "Failed to open population csv sheet: $!\n";
	my %populations;
	while( <PCSV> )
	{
		chomp;
		next unless length( $_ ) > 0 && $_ !~ /^\s+$/ && $_ !~ /^,+$/;
		
		my @s = split( /,/, $_ );
		$populations{ $s[ 1 ] } = $s[ 5 ];
	}
	close( PCSV );
	
	my %exp_path; #within hierarchy
	
	croak "Cant find input index file\n" unless -f $index_file;
	
	open( IN, "$index_file" ) or die "Cannot open input index file\n";
	while( <IN> )
	{
		chomp;
		next if( $_ =~ /^\s+$/ || length( $_ ) == 0 || $_ =~ /^FASTQ_FILE/ );
		
		my @info = split( /\t+/, $_ );
		croak "Cant find study for lane ID: $info[ 3 ]\n" if( ! defined $study_vs_id{ $info[ 3 ] } );
		croak "Cant find population for lane ID: $info[ 9 ]\n" if( ! defined $populations{ $info[ 9 ] } );
		
		my @s = split( /\t+/, $_ );
		
		my $path = $hierarchy_dir.'/'.$study_vs_id{ $info[ 3 ] }.'-'.$populations{ $info[ 9 ] }.'/'.$info[ 9 ];
			
		#technology
		if( $info[ 12 ] =~ /454/ )
		{
			$path = $path.'/454';
		}
		elsif( $info[ 12 ] =~ /solid/i )
		{
			$path = $path.'/SOLID';
		}
		elsif( $info[ 12 ] =~ /solexa/i || $info[ 12 ] =~ /illumina/i )
		{
			$path = $path.'/SLX';
		}
		else
		{
			croak "Cannot determine sequencing technology: $info[ 12 ]\n";
		}
		$path .= '/'.$info[ 15 ];
		
		#see if we can find the lane fastq file
		my @fastq = <$path/*/*.fastq.gz>;
		my $alreadyImported = 0;
		my $fastqFile = $info[ 0 ];
		my $found = 0;
		foreach( @fastq )
		{
			chomp;
			if( basename( $_ ) eq $fastqFile )
			{
				#delete the lane directory
				my $dirname = dirname( $_ );
				system( "rm -rf $dirname" );
				print "Deleteing: $dirname\n";
				$found = 1;
				last;
			}
		}
		print "Cannot locate: $fastqFile\n" if( $found == 0 );
	}
	close( IN );
}

#a function to go through the mapping hierarchy and flag up lanes that failed mapping
sub auditMappingHierarchy
{
	croak "Usage: auditMappingHierarchy hierarchyRootDir projects_dir_list lane_summary [sequence.index]" unless @_ == 4 || @_ == 3;
	
	my $mapping_root = shift;
	my $projects = shift;
	my $laneSummary = shift;
	
	my $indexF = '';
	if( @_ > 0 )
	{
		$indexF = shift;
		croak "Cant find index file" unless -f $indexF;
	}
	
	croak "Cant find mapping root directory" unless -d $mapping_root;
	croak "Cant find projects file" unless -f $projects;
	
	my %projects;
	open( P, $projects ) or die $!;
	while( <P> )
	{
		chomp;
		$_ =~ tr/ /_/;
		$projects{ $_} = 1;
	}
	close( P );
	
	chdir( $mapping_root );
	
	open( LSUM, ">$laneSummary" ) or die $!;
	
	print LSUM "Status,Center,Project,Individual,Tech,Library,Lane,Fastq0,ReadLength,Fastq1,ReadLength,Fastq2,ReadLength,#Reads,#Bases,#RawReadsMapped,#RawBasesMapped,#ReadsPaired,ErrorRate\n";
	
	my $completedLanes = 0;
	my $totalLanes = 0;
	
	foreach my $project (`ls`) 
	{
		chomp( $project );
		
		$project =~ tr/ /_/;
		print "Checking $project\n";
		if( -d $project && $projects{ $project } )
		{
			chdir( $project );
			print "In ".getcwd."\n";
			
			foreach my $individual (`ls`) 
			{
				chomp( $individual );
				if( -d $individual )
				{
					chdir( $individual );
					print "In ".getcwd."\n";
					
					foreach my $technology (`ls`)
					{
						chomp( $technology );
						if( -d $technology )
						{
							chdir( $technology );
							print "In ".getcwd."\n";
						
							foreach my $library (`ls`) 
							{
								chomp( $library );
								if( -d $library )
								{
									chdir( $library );
									print "In ".getcwd."\n";
									
									my $libraryLanesCompleted = 1;
									
									foreach my $lane (`ls`) 
									{
										chomp( $lane );
										if( -d $lane )
										{
											chdir( $lane );
											print "In ".getcwd."\n";
											
											my $center = '';
											if( -f $indexF )
											{
												my $accession = basename( getcwd() );
												$center = `grep $accession $indexF | awk -F"\t" '{print \$6}' | head -1`;
												chomp( $center );
											}
											
											my $paired = 0;
											my $lane_read0 = '';
											my $lane_read1 = '';
											my $lane_read2 = '';
											my $num_bases0 = 0;
											my $num_bases1 = 0;
											my $num_bases2 = 0;
											my $num_reads0 = 0;
											my $num_reads1 = 0;
											my $num_reads2 = 0;
											my $readLength0 = 0;
											my $readLength1 = 0;
											my $readLength2 = 0;
											if( -f "meta.info" || -l "meta.info" )
											{
												$lane_read0=`grep read0 meta.info | head -1 | awk -F: '{print \$2}'`;
												$lane_read1=`grep read1 meta.info | head -1 | awk -F: '{print \$2}'`;
												$lane_read2=`grep read2 meta.info | head -1 | awk -F: '{print \$2}'`;
												
												chomp( $lane_read0 );
												chomp( $lane_read1 );
												chomp( $lane_read2 );
												
												if( length( $lane_read1 ) > 0 && length( $lane_read2 ) > 0 )
												{
													$paired = 1;
													
													$num_bases1 = `cat $lane_read1.fastqcheck | head -1 | awk '{print \$3}'`;chomp( $num_bases1 );
													$num_reads1 = `cat $lane_read1.fastqcheck | head -1 | awk '{print \$1}'`;chomp( $num_reads1 );
													$num_bases2 = `cat $lane_read2.fastqcheck | head -1 | awk '{print \$3}'`;chomp( $num_bases2 );
													$num_reads2 = `cat $lane_read2.fastqcheck | head -1 | awk '{print \$1}'`;chomp( $num_reads2 );
													$readLength1 = `cat $lane_read1.fastqcheck | head -1 | awk '{print \$6}'`;chomp( $readLength1 );
													$readLength2 = `cat $lane_read2.fastqcheck | head -1 | awk '{print \$6}'`;chomp( $readLength2 );
												}
												else
												{
													$num_bases0 = `cat $lane_read0.fastqcheck | head -1 | awk '{print \$3}'`;chomp( $num_bases0 );
													$num_reads0 = `cat $lane_read0.fastqcheck | head -1 | awk '{print \$1}'`;chomp( $num_reads0 );
													$readLength0 = `cat $lane_read0.fastqcheck | head -1 | awk '{print \$6}'`;chomp( $readLength0 );
												}
											}
											else
											{
												print "ERROR: No meta.info file found: ".getcwd()."\n";
												chdir( ".." );
												next;
											}
											
											$totalLanes ++;
											
											my $rawNumReads = 0;
											my $mappedNumReads = 0;
											my $rawPairedNumReads = 0;
											my $successfulLane = 1;
											
											if( $technology =~ /^SLX$/ )
											{
												my $rawMappedReads = 0;
												my $rawMappedBases = 0;
												my $rmdupMappedReads = 0;
												my $rmdupMappedBases = 0;
												my $errorRate = 0;
												if( -s "raw.map.mapstat" )
												{
													my $isLastIteration = 0;
													my $lastFileName = '';
													
													my @outputs = (`ls -l split*.maq.out.gz | sort -k 4 -r | awk '{print \$9}'`);
													
													for( my $i = 0; $i < @outputs; $i ++ )
													{
														chomp( $outputs[ $i ] );
														
														my $line=`zcat $outputs[ $i ] | tail -5 | grep '(total, isPE, mapped, paired)'`;
														my $zeroReads=`zcat $outputs[ $i ] | head -5`;
														if( $zeroReads !~ /\[ma_load_reads\]\s+0\*2\s+reads\s+loaded\./ )
														{
															if( length( $line ) > 0 )
															{
																$line =~ /.*=\s+\((\d+),\s+(\d+),\s+(\d+),\s+(\d+)\)/;
																
																$rawNumReads += $1;
																$mappedNumReads += $3;
																$rawPairedNumReads += $4;
															}
															else
															{
																print "1BAD_LANE_SPLIT: $outputs[ $i ] ".getcwd."\n";
																$successfulLane = 0;
															}
														}
														else 
														{
														# jws - what does this state mean: pass or fail?
														}
													}
													
													#verify the number of reads agrees with the mapstat file
													$rawMappedReads = `head raw.map.mapstat | grep 'Total number of reads' | awk -F":" '{print \$2}'`;chomp( $rawMappedReads );
													$rawMappedBases = `head raw.map.mapstat | grep 'Sum of read length' | awk -F":" '{print \$2}'`;chomp( $rawMappedBases );
													$errorRate = `head raw.map.mapstat | grep 'Error rate' | awk -F":" '{print \$2}'`;chomp( $errorRate );

													#$rmdupMappedReads = `head rmdup.map.mapstat | grep 'Total number of reads' | awk -F":" '{print \$2}'`;chomp( $rmdupMappedReads );
													#$rmdupMappedBases = `head rmdup.map.mapstat | grep 'Sum of read length' | awk -F":" '{print \$2}'`;chomp( $rmdupMappedBases );
													
													if( $rawMappedReads != $mappedNumReads )
													{
														print "Number of reads in mapstat not equal to split outputs: $rawMappedReads vs. $mappedNumReads\n";
														print "BAD_LANE_MAPSTAT: ".getcwd."\n";
														$successfulLane = 0;
													}
													
											
												}
												else
												{
													print "INCOMPLETE: Can't find mapstat file\n";
													$successfulLane = 0;
												}

												if( $successfulLane == 1 )
												{
													$completedLanes ++ ;
													print LSUM "MAPPED,$center,$project,$individual,$technology,$library,$lane,";
													if( length( $lane_read0 ) > 0 )
													{
														print LSUM "$lane_read0,$readLength0,,,,,$num_reads0,$num_bases0,$rawMappedReads,$rawMappedBases,0,$errorRate\n";
													}
													else
													{
														print LSUM ",,$lane_read1,$readLength1,$lane_read2,$readLength2,".($num_reads1+$num_reads2).",".($num_bases1 + $num_bases2).",$rawMappedReads,$rawMappedBases,$rawPairedNumReads,$errorRate\n";
													}
												}
												else 
												{
												    print LSUM "NOT_MAPPED,$center,$project,$individual,$technology,$library,$lane,";
												    if( length( $lane_read0 ) > 0 )
												    {
													print LSUM "$lane_read0,$readLength0,,,,,$num_reads0,$num_bases0\n";
												    }
												    else
												    {
													print LSUM ",,$lane_read1,$readLength1,$lane_read2,$readLength2,".($num_reads1+$num_reads2).",".($num_bases1 + $num_bases2)."\n";
												    }
												}
											}
											elsif( $technology =~ /^454$/ )
											{
												my $paired = 0;
												my $lane_read0 = '';
												my $lane_read1 = '';
												my $lane_read2 = '';
												my $num_bases0 = 0;
												my $num_bases1 = 0;
												my $num_bases2 = 0;
												my $num_reads0 = 0;
												my $num_reads1 = 0;
												my $num_reads2 = 0;
												if( -f "meta.info" || -l "meta.info" )
												{
													$lane_read0=`grep read0 meta.info | head -1 | awk -F: '{print \$2}'`;
													$lane_read1=`grep read1 meta.info | head -1 | awk -F: '{print \$2}'`;
													$lane_read2=`grep read2 meta.info | head -1 | awk -F: '{print \$2}'`;
													
													chomp( $lane_read0 );
													chomp( $lane_read1 );
													chomp( $lane_read2 );
													
													if( length( $lane_read1 ) > 0 && length( $lane_read2 ) > 0 )
													{
														$paired = 1;
														
														$num_bases1 = `cat $lane_read1.fastqcheck | head -1 | awk '{print \$3}'`;chomp( $num_bases1 );
														$num_reads1 = `cat $lane_read1.fastqcheck | head -1 | awk '{print \$1}'`;chomp( $num_reads1 );
														$num_bases2 = `cat $lane_read2.fastqcheck | head -1 | awk '{print \$3}'`;chomp( $num_bases2 );
														$num_reads2 = `cat $lane_read2.fastqcheck | head -1 | awk '{print \$1}'`;chomp( $num_reads2 );
														$readLength1 = `cat $lane_read1.fastqcheck | head -1 | awk '{print \$6}'`;chomp( $readLength1 );
														$readLength2 = `cat $lane_read2.fastqcheck | head -1 | awk '{print \$6}'`;chomp( $readLength2 );
													}
													
													if( length( $lane_read0 ) > 0 )
													{
														$num_bases0 = `cat $lane_read0.fastqcheck | head -1 | awk '{print \$3}'`;chomp( $num_bases0 );
														$num_reads0 = `cat $lane_read0.fastqcheck | head -1 | awk '{print \$1}'`;chomp( $num_reads0 );
														$readLength0 = `cat $lane_read0.fastqcheck | head -1 | awk '{print \$6}'`;chomp( $readLength0 );
													}
												}
												else
												{
													print "ERROR: No meta.info file found: ".getcwd()."\n";
													chdir( ".." );
													next;
												}
												
												#check to see if the lane is mapped
												my $finished = 1;
												foreach my $fastq (`ls *.fastq.gz`)
												{
													chomp( $fastq );
													next unless -f $fastq;
													
													my @s = split( /\./, $lane_read0 );
													my $cigarName = $s[ 0 ].'.'.$s[ 1 ].'.cigar.gz';
													if( -f $cigarName )
													{
														my $t = `zcat $cigarName | tail -5 | grep "^SSAHA2 finished" | wc -l`;
														chomp( $t );
														# jws - I think this change is required otherwise unfinished ssaha2 won't cause failure
														unless( $t == 1 )
														{
															$finished = 0;
															last;
														}
													}
													else
													{
														$finished = 0;
														last;
													}
												}
												
												if( $finished == 1 )
												{
													print LSUM "MAPPED,$center,"
												}
												else
												{
													print LSUM "NOT_MAPPED,$center,";
												}
												
												print LSUM "$project,$individual,$technology,$library,$lane,$lane_read0,$readLength0,$lane_read1,$readLength1,$lane_read2,$readLength2,".($num_reads0 + $num_reads1 + $num_reads2).",".($num_bases0 + $num_bases1 + $num_bases2)."\n";
												
											}
											
											chdir( ".." );
										}
									}
									chdir( ".." );
								}
							}
							chdir( ".." );
						}
					}
					chdir( ".." );
				}
			}
			chdir( ".." );
		}
	}
	
	close( LSUM );
	print $completedLanes." / $totalLanes fully completed\n";
}

sub syncIndexFile
{
	croak "Usage: syncIndexFile index_file dataRootDir mappingRootDir" unless @_ == 3;
	
	my $index_file = shift;
	my $dRoot = shift;
	my $mRoot =  shift;
	
	croak "Cant find index file" unless -f $index_file;
	croak "Cant find data root directory" unless -d $dRoot;
	croak "Cant find mapping root directory" unless -d $mRoot;
	
	open( MIS, ">$index_file.missing.index" ) or die $!;
	
	open( WITH, ">remove_withdrawn.sh" ) or die $!;
	open( INCOMPLETE, ">remove_incomplete.sh" ) or die $!;
	open( IN, $index_file ) or die "Cannot open index file\n";
	while( <IN> )
	{
		chomp;
		
		next unless $_ !~ /FASTQ/;
		
		my @paths = @{ indexLineToPaths( $_ ) };
		my @s = split( /\t/, $_ );
		
		if( ! -d $dRoot."/".$paths[ 0 ] )
		{
			print "LIBRARY_NOT_FOUND: $dRoot/$paths[ 0 ]\n";
			print MIS $_."\n";
			next;
		}
		
		#check if the lane has been withdrawn
		if( -d $dRoot."/".$paths[ 1 ] && $s[ 20 ] == 1 )
		{
			print "WITHDRAWN: $dRoot/$paths[ 1 ]\n";
			
			#delete the directory in the mapping and data hierarchies
			print WITH "rm -rf $dRoot/$paths[ 1 ] $mRoot/$paths[ 1 ]\n";
			
			next;
		}
		
		if( ! -d $dRoot."/".$paths[ 1 ] )
		{
			#check the file has not been withdrawn
			if( $s[ 20 ] == 0 )
			{
				print "LANE_NOT_FOUND: $_\t$dRoot/$paths[ 1 ]\n";
				print MIS $_."\n";
			}
		}
		elsif( ! -f $dRoot."/".$paths[ 2 ] )
		{
			#check the file has not been withdrawn
			if( $s[ 20 ] == 0 )
			{
				print "FASTQ_NOT_FOUND: $_\t$dRoot/$paths[ 2 ]\n";
				print INCOMPLETE "rm -rf $dRoot/$paths[ 1 ] $mRoot/$paths[ 1 ]\n";
				print MIS $_."\n";
			}
		}
		else
		{
			print "AGREE: $dRoot/$paths[ 1 ]\n";
		}
	}
	close( IN );
	close( MIS );
	close( WITH );
	close( INCOMPLETE );
}

#takes an index line and returns 3 paths (the library path, lane path, fastq path)
sub indexLineToPaths
{
	croak "Usage: indexLineToPath index_line" unless @_ == 1;
	
	my $index_line = shift;
	
	my @s = split( /\t/, $index_line );
	
	my @paths;
	
	my $individualPath = determineIndividualProjectDir( $s[ 9 ], $s[ 3 ] )."/".$s[ 9 ];
	
	#technology
	if( $s[ 12 ] =~ /454|roche/i )
	{
		$individualPath = $individualPath.'/454';
	}
	elsif( $s[ 12 ] =~ /solid/i )
	{
		$individualPath = $individualPath.'/SOLID';
	}
	elsif( $s[ 12 ] =~ /solexa|illumina/i )
	{
		$individualPath = $individualPath.'/SLX';
	}
	else
	{
		croak "Cannot determine sequencing technology: $s[ 12 ]\n";
	}
	
	my $libraryPath = $individualPath."/".$s[ 14 ];
	push( @paths, $libraryPath );
	
	my $lanePath = $libraryPath.'/'.$s[ 2 ];
	push( @paths, $lanePath );
	
	my $fastqPath = $lanePath.'/'.basename( $s[ 0 ] );
	push( @paths, $fastqPath );
	
	return \@paths;
}

my $SAMPLES_CSV = $ENV{ 'G1K' }.'/G1K/meta-data/G1K_samples.txt';
my %G1K_SAMPLES;
sub determineIndividualProjectDir
{
	croak "Usage: determineIndividualProject individual proj_code" unless @_ == 2;
	
	my $individual = shift;
	my $proj_code =  shift;
	
	my %study_vs_id = (
			28911   => 'LowCov',  # pilot 1
		    28919   => 'Trio',    # pilot 2
		    28917   => 'Exon',    # pilot 3
		    'SRP000031'   => 'LowCov',    # pilot 1
		    'SRP000032'   => 'Trio',    # pilot 2
		    'SRP000033'   => 'Exon',    # pilot 3
		    'Pilot1'   => 'LowCov',    # pilot 1
		    'Pilot2'   => 'LowCov',    # pilot 1
		    'Pilot3'   => 'LowCov',    # pilot 1
		    );
	
	#read in the project spreadsheet with individuals
	if( keys( %G1K_SAMPLES ) == 0 )
	{
		open( PCSV, $SAMPLES_CSV ) or die "Failed to open population csv sheet: $!\n";
		while( <PCSV> )
		{
			chomp;
			next unless length( $_ ) > 0 && $_ !~ /^\s+$/ && $_ !~ /^,+$/;
			
			my @s = split( /,/, $_ );
			$G1K_SAMPLES{ $s[ 1 ] } = $s[ 5 ];
		}
		close( PCSV );
	}
	
	if( ! defined $study_vs_id{ $proj_code } )
	{
		croak "Undefined project code: $proj_code\n";
	}
	
	if( ! defined $G1K_SAMPLES{ $individual } )
	{
		croak "Undefined individual: $individual"."x\n";
	}
	
	return $study_vs_id{ $proj_code }.'-'.$G1K_SAMPLES{ $individual };
}

sub markFailedGenotypeLanes
{
	croak "Usage: markBadLanes fileOfAccessions data_root index_file" unless @_ == 3;
	
	my $accessions = shift;
	my $dRoot =  shift;
	my $indexF = shift;
	
	croak "Cant find accessions file: $accessions\n" unless -f $accessions;
	croak "Cant find index file: $indexF\n" unless -f $indexF;
	croak "Cant find data root directory: $dRoot\n" unless -d $dRoot;
	
	my %accessions;
	open( A, $accessions ) or die "failed to open accessions file: $accessions $!\n";
	while( <A> )
	{
		chomp;
		my $acc = (split( /\t/, $_))[ 0 ];
		$accessions{ $acc } = 1;
	}
	close( A );

	open( IN, $indexF ) or die "Cant open index file: $indexF\n";
	while( <IN> )
	{
		chomp;
		my $acc = (split( /\t/, $_))[ 2 ];

		if( defined( $accessions{ $acc } ) )
		{
			my @paths = @{ indexLineToPaths( $_ ) };
			
			my $meta = $dRoot."/".$paths[ 1 ]."/meta.info";
			if( -f $meta )
			{
				open( M, ">>$meta" ) or die "Cant open $meta\n";
				print M "genotype:fail\n";
				close( M );
			}
		}
	}
	close( IN );
}

sub pathmk {
   my @parts = File::Spec->splitdir( shift() );
   my $nofatal = shift;
   my $pth = $parts[0];
   my $zer = 0;
   if(!$pth) {
      $pth = File::Spec->catdir($parts[0],$parts[1]);
      $zer = 1;
   }
   my $DirPerms = '';
   for($zer..$#parts) {
      $DirPerms = oct($DirPerms) if substr($DirPerms,0,1) eq '0';
      mkdir($pth,$DirPerms) or return if !-d $pth && !$nofatal;
      mkdir($pth,$DirPerms) if !-d $pth && $nofatal;
      $pth = File::Spec->catdir($pth, $parts[$_ + 1]) unless $_ == $#parts;
   }
   1;
}

1;
