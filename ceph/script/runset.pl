#!/usr/bin/perl

use strict;
use Data::Dumper;

=item sample input file

# hi there
{
	# startup
	'n' => 30,          # mpi nodes
	'sleep' => 10,      # seconds between runs
	'nummds' => 1,
	'numosd' => 8,
	'numclient' => 400,#[10, 50, 100, 200, 400],

	# parameters
	'fs' => [ 'ebofs', 'fakestore' ],
	'until' => 150,     # --syn until $n    ... when to stop clients
	'writefile' => 1,
	'writefile_size' => [ 4096, 65526, 256000, 1024000, 2560000 ],
	'writefile_mb' => 1000,

	'custom' => '--tcp_skip_rank0 --osd_maxthreads 0';

	# for final summation (script/sum.pl)
	'start' => 30,
	'end' => 120,

	'_psub' => 'alc.tp'   # switch to psub mode!
};

=cut

my $usage = "script/runset.pl jobs/some/job blah\n";

my $in = shift || die $usage;
my $tag = shift || die $usage;
my $fake = shift;


my ($job) = $in =~ /^jobs\/(.*)/;
my ($jname) = $job =~ /\/(\w+)$/;
$jname ||= $job;
die "not jobs/?" unless defined $job;
my $out = "log/$job.$tag";



print "--- job $job, tag $tag ---\n";


# get input
my $raw = `cat $in`;
my $sim = eval $raw;
unless (ref $sim) {
	print "bad input: $in\n";
	system "perl -c $in";
	exit 1;
}

open(W, "$out/in");
print W $raw;
close W;

my $comb = $sim->{'comb'};
delete $sim->{'comb'};
my %filters;
my @fulldirs;

# prep output
system "mkdir -p $out" unless -d "$out";


sub iterate {
	my $sim = shift @_;
	my $fix = shift @_ || {};
	my $vary;
	my @r;

	my $this;
	for my $k (sort keys %$sim) {
		next if $k =~ /^_/;
		if (defined $fix->{$k}) {
			$this->{$k} = $fix->{$k};
		}
		elsif (ref $sim->{$k} eq 'HASH') {
			# nothing
		}
		elsif (!(ref $sim->{$k})) {
			$this->{$k} = $sim->{$k};
		}
		else {
			#print ref $sim->{$k};
			if (!(defined $vary)) {
				$vary = $k;
			}
		}
	}

	if ($vary) {
		#print "vary $vary\n";
		for my $v (@{$sim->{$vary}}) {
			$this->{$vary} = $v;
			push(@r, &iterate($sim, $this));
		}
	} else {

		if ($sim->{'_dep'}) {
			my @s = @{$sim->{'_dep'}};
			while (@s) {
				my $dv = shift @s;
				my $eq = shift @s;

				$eq =~ s/\$(\w+)/"\$this->{'$1'}"/eg;
				$this->{$dv} = eval $eq;
				#print "$dv : $eq -> $this->{$dv}\n";
			}
		}

		push(@r, $this);
	}
	return @r;
}

sub run {
	my $h = shift @_;

	my @fn;
	my @filt;
	for my $k (sort keys %$sim) {
		next if $k =~ /^_/;
		next unless ref $sim->{$k} eq 'ARRAY';
		push(@fn, "$k=$h->{$k}");
		next if $comb && $k eq $comb->{'x'};
		push(@filt, "$k=$h->{$k}");
	}
	my $keys = join(",", @fn);
	$keys =~ s/ /_/g;
	my $fn = $out . '/' . $keys;
	my $name = $jname . '_' . $tag . '_' . $keys;

	push( @fulldirs, "" . $fn );

	
	# filters
	$filters{ join(',', @filt) } = 1;


	if (-e "$fn/.done") {
		print "already done.\n";
		return;
	}
	system "rm -r $fn" if -d "$fn";
	system "mkdir $fn" unless -d "$fn";

	my $e = './tcpsyn';
	$e = './tcpsynobfs' if $h->{'fs'} eq 'obfs';
	my $c = "mpiexec -l -n $h->{'n'} $e --mkfs";
	$c .= " --$h->{'fs'}";
	$c .= " --syn until $h->{'until'}" if $h->{'until'};

	$c .= " --syn writefile $h->{'writefile_mb'} $h->{'writefile_size'}" if $h->{'writefile'};
	$c .= " --syn makedirs $h->{'makedirs_dirs'} $h->{'makedirs_files'} $h->{'makedirs_depth'}" if $h->{'makedirs'};

	for my $k ('nummds', 'numclient', 'numosd', 'kill_after',
			   'osd_maxthreads', 'osd_object_layout', 'osd_pg_layout','osd_pg_bits',
			   'bdev_el_bidir', 'ebofs_idle_commit_ms', 'ebofs_commit_ms', 
			   'ebofs_oc_size','ebofs_cc_size','ebofs_bc_size','ebofs_bc_max_dirty','ebofs_abp_max_alloc') {
		$c .= " --$k $h->{$k}" if defined $h->{$k};
	}

	$c .= ' ' . $h->{'custom'} if $h->{'custom'};

	$c .= " --log_name $fn";

	
	if ($sim->{'_psub'}) {
		# template!
		my $tp = `cat $sim->{'_psub'}`;
		$tp =~ s/\$NAME/$name/g;
		$tp =~ s/\$NUM/$h->{'n'}/g;
		$tp =~ s/\$OUT/$fn\/o/g;
		$tp =~ s/\$CMD/$c/g;
		open(O,">$out/psub.$name");
		print O $tp;
		close O;
		return;
	} else {
		# run
		print "-> $c\n";
		my $r = 0;
		unless ($fake) {
			$r = system "$c > $fn/o";
			system "script/sum.pl -start $h->{'start'} -end $h->{'end'} $fn/osd* > $fn/sum.osd";
			system "script/sum.pl -start $h->{'start'} -end $h->{'end'} $fn/mds* > $fn/sum.mds"
				if -e "$fn/mds1";
			system "script/sum.pl -start $h->{'start'} -end $h->{'end'} $fn/clnode* > $fn/sum.cl"
				if -e "$fn/clnode.1";
			if ($r) {
				print "r = $r\n";
			} else {
				system "touch $fn/.done";
			}
		}
		return $r;
	}
}



my @r = &iterate($sim);
my $n = scalar(@r);
my $c = 1;
my %r;
my $nfailed = 0;
for my $h (@r) {
	my $d = `date`;
	chomp($d);
	$d =~ s/ P.T .*//;
	print "=== $c/$n";
	print " ($nfailed failed)" if $nfailed;
	print " $d: ";
	my $r = &run($h);

	if (!(defined $r)) {
		# already done
	} else {
		if ($r) {
			$nfailed++;
		}
		print "sleep $h->{'sleep'}\n";
		sleep $h->{'sleep'};
	}

	$c++;
}
print "$nfailed failed\n";


my @comb;
if ($comb) {
	my $x = $comb->{'x'};
	my @vars = @{$comb->{'vars'}};

	my @filters = sort keys %filters;
	my $cmd = "script/comb.pl $x @vars - @fulldirs - @filters > $out/c";
	print "\n$c\n";
	system $cmd;

	print "set data style linespoints;\n";
	my $s = 2;
	for my $v (@vars) {
		my $c = $s;
		$s++;
		my @p;
		for my $f (@filters) {
			my $t = $f;
			if ($comb->{'maptitle'}) {
				for my $a (keys %{$comb->{'maptitle'}}) {
					my $b = $comb->{'maptitle'}->{$a};
					$t =~ s/$a/$b/;
				}
			}
			push (@p, "\"$out/c\" u 1:$c t \"$t\"" );
			$c += scalar(@vars);
		}
		print "# $v\nplot " . join(", ", @p) . ";\n\n";
	}
}

