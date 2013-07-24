#! /usr/bin/perl
#
# dpkg-source
#
# Copyright © 1996 Ian Jackson <ian@davenant.greenend.org.uk>
# Copyright © 1997 Klee Dienes <klee@debian.org>
# Copyright © 1999-2003 Wichert Akkerman <wakkerma@debian.org>
# Copyright © 1999 Ben Collins <bcollins@debian.org>
# Copyright © 2000-2003 Adam Heath <doogie@debian.org>
# Copyright © 2005 Brendan O'Dea <bod@debian.org>
# Copyright © 2006-2008 Frank Lichtenheld <djpig@debian.org>
# Copyright © 2006-2009,2012 Guillem Jover <guillem@debian.org>
# Copyright © 2008-2011 Raphaël Hertzog <hertzog@debian.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use strict;
use warnings;

use Dpkg ();
use Dpkg::Gettext;
use Dpkg::ErrorHandling;
use Dpkg::Util qw(:list);
use Dpkg::Arch qw(debarch_eq debarch_is debarch_is_wildcard);
use Dpkg::Deps;
use Dpkg::Compression;
use Dpkg::Conf;
use Dpkg::Control::Info;
use Dpkg::Control::Fields;
use Dpkg::Substvars;
use Dpkg::Version;
use Dpkg::Vars;
use Dpkg::Changelog::Parse;
use Dpkg::Source::Package;
use Dpkg::Vendor qw(run_vendor_hook);

use Cwd;
use File::Basename;
use File::Spec;

textdomain('dpkg-dev');

my $controlfile;
my $changelogfile;
my $changelogformat;

my $build_format;
my %options = (
    # Compression related
    compression => compression_get_default(),
    comp_level => compression_get_default_level(),
    comp_ext => compression_get_property(compression_get_default(), 'file_ext'),
    # Ignore files
    tar_ignore => [],
    diff_ignore_regexp => '',
    # Misc options
    copy_orig_tarballs => 1,
    no_check => 0,
    require_valid_signature => 0,
);

# Fields to remove/override
my %remove;
my %override;

my $substvars = Dpkg::Substvars->new();
my $tar_ignore_default_pattern_done;

my @options;
my @cmdline_options;
while (@ARGV && $ARGV[0] =~ m/^-/) {
    $_ = shift(@ARGV);
    if (m/^-b$/) {
        setopmode('-b');
    } elsif (m/^-x$/) {
        setopmode('-x');
    } elsif (m/^--(before|after)-build$/) {
        setopmode($_);
    } elsif (m/^--commit$/) {
        setopmode($_);
    } elsif (m/^--print-format$/) {
	setopmode('--print-format');
	report_options(info_fh => \*STDERR); # Avoid clutter on STDOUT
    } else {
	push @options, $_;
    }
}

my $dir;
if (defined($options{opmode}) &&
    $options{opmode} =~ /^(-b|--print-format|--(before|after)-build|--commit)$/) {
    if (not scalar(@ARGV)) {
	usageerr(_g('%s needs a directory'), $options{opmode})
	    unless $1 eq '--commit';
	$dir = '.';
    } else {
	$dir = File::Spec->catdir(shift(@ARGV));
    }
    stat($dir) || syserr(_g('cannot stat directory %s'), $dir);
    if (not -d $dir) {
	error(_g('directory argument %s is not a directory'), $dir);
    }
    if ($dir eq '.') {
	# . is never correct, adjust automatically
	$dir = basename(cwd());
	chdir('..') || syserr(_g("unable to chdir to `%s'"), '..');
    }
    # --format options are not allowed, they would take precedence
    # over real command line options, debian/source/format should be used
    # instead
    # --unapply-patches is only allowed in local-options as it's a matter
    # of personal taste and the default should be to keep patches applied
    my $forbidden_opts_re = {
	'options' => qr/^--(?:format=|unapply-patches$|abort-on-upstream-changes$)/,
	'local-options' => qr/^--format=/,
    };
    foreach my $filename ('local-options', 'options') {
	my $conf = Dpkg::Conf->new();
	my $optfile = File::Spec->catfile($dir, 'debian', 'source', $filename);
	next unless -f $optfile;
	$conf->load($optfile);
	$conf->filter(remove => sub { $_[0] =~ $forbidden_opts_re->{$filename} });
	if (@$conf) {
	    info(_g('using options from %s: %s'), $optfile, join(' ', @$conf))
		unless $options{opmode} eq '--print-format';
	    unshift @options, @$conf;
	}
    }
}

while (@options) {
    $_ = shift(@options);
    if (m/^--format=(.*)$/) {
	$build_format //= $1;
    } elsif (m/^-(?:Z|-compression=)(.*)$/) {
	my $compression = $1;
	$options{compression} = $compression;
	$options{comp_ext} = compression_get_property($compression, 'file_ext');
	usageerr(_g('%s is not a supported compression'), $compression)
	    unless compression_is_supported($compression);
	compression_set_default($compression);
    } elsif (m/^-(?:z|-compression-level=)(.*)$/) {
	my $comp_level = $1;
	$options{comp_level} = $comp_level;
	usageerr(_g('%s is not a compression level'), $comp_level)
	    unless compression_is_valid_level($comp_level);
	compression_set_default_level($comp_level);
    } elsif (m/^-c(.*)$/) {
        $controlfile = $1;
    } elsif (m/^-l(.*)$/) {
        $changelogfile = $1;
    } elsif (m/^-F([0-9a-z]+)$/) {
        $changelogformat = $1;
    } elsif (m/^-D([^\=:]+)[=:](.*)$/s) {
        $override{$1} = $2;
    } elsif (m/^-U([^\=:]+)$/) {
        $remove{$1} = 1;
    } elsif (m/^-(?:i|-diff-ignore(?:$|=))(.*)$/) {
        $options{diff_ignore_regexp} = $1 ? $1 : $Dpkg::Source::Package::diff_ignore_default_regexp;
    } elsif (m/^--extend-diff-ignore=(.+)$/) {
	$Dpkg::Source::Package::diff_ignore_default_regexp .= "|$1";
	if ($options{diff_ignore_regexp}) {
	    $options{diff_ignore_regexp} .= "|$1";
	}
    } elsif (m/^-(?:I|-tar-ignore=)(.+)$/) {
        push @{$options{tar_ignore}}, $1;
    } elsif (m/^-(?:I|-tar-ignore)$/) {
        unless ($tar_ignore_default_pattern_done) {
            push @{$options{tar_ignore}}, @Dpkg::Source::Package::tar_ignore_default_pattern;
            # Prevent adding multiple times
            $tar_ignore_default_pattern_done = 1;
        }
    } elsif (m/^--no-copy$/) {
        $options{copy_orig_tarballs} = 0;
    } elsif (m/^--no-check$/) {
        $options{no_check} = 1;
    } elsif (m/^--require-valid-signature$/) {
        $options{require_valid_signature} = 1;
    } elsif (m/^-V(\w[-:0-9A-Za-z]*)[=:](.*)$/s) {
        $substvars->set($1, $2);
    } elsif (m/^-T(.*)$/) {
	$substvars->load($1) if -e $1;
    } elsif (m/^-(\?|-help)$/) {
        usage();
        exit(0);
    } elsif (m/^--version$/) {
        version();
        exit(0);
    } elsif (m/^-[EW]$/) {
        # Deprecated option
        warning(_g('-E and -W are deprecated, they are without effect'));
    } elsif (m/^-q$/) {
        report_options(quiet_warnings => 1);
        $options{quiet} = 1;
    } elsif (m/^--$/) {
        last;
    } else {
        push @cmdline_options, $_;
    }
}

unless (defined($options{opmode})) {
    usageerr(_g('need a command (-x, -b, --before-build, --after-build, --print-format, --commit)'));
}

if ($options{opmode} =~ /^(-b|--print-format|--(before|after)-build|--commit)$/) {

    $options{ARGV} = \@ARGV;

    $changelogfile ||= "$dir/debian/changelog";
    $controlfile ||= "$dir/debian/control";

    my %ch_options = (file => $changelogfile);
    $ch_options{changelogformat} = $changelogformat if $changelogformat;
    my $changelog = changelog_parse(%ch_options);
    my $control = Dpkg::Control::Info->new($controlfile);

    my $srcpkg = Dpkg::Source::Package->new(options => \%options);
    my $fields = $srcpkg->{fields};

    my @sourcearch;
    my %archadded;
    my @binarypackages;

    # Scan control info of source package
    my $src_fields = $control->get_source();
    error(_g("%s doesn't contain any information about the source package"),
          $controlfile) unless defined $src_fields;
    my $src_sect = $src_fields->{'Section'} || 'unknown';
    my $src_prio = $src_fields->{'Priority'} || 'unknown';
    foreach (keys %{$src_fields}) {
	my $v = $src_fields->{$_};
	if (m/^Source$/i) {
	    set_source_package($v);
	    $fields->{$_} = $v;
	} elsif (m/^Uploaders$/i) {
	    ($fields->{$_} = $v) =~ s/\s*[\r\n]\s*/ /g; # Merge in a single-line
	} elsif (m/^Build-(Depends|Conflicts)(-Arch|-Indep)?$/i) {
	    my $dep;
	    my $type = field_get_dep_type($_);
	    $dep = deps_parse($v, build_dep => 1, union => $type eq 'union');
	    error(_g('error occurred while parsing %s'), $_) unless defined $dep;
	    my $facts = Dpkg::Deps::KnownFacts->new();
	    $dep->simplify_deps($facts);
	    $dep->sort() if $type eq 'union';
	    $fields->{$_} = $dep->output();
	} else {
            field_transfer_single($src_fields, $fields);
	}
    }

    # Scan control info of binary packages
    my @pkglist;
    foreach my $pkg ($control->get_packages()) {
	my $p = $pkg->{'Package'};
	my $sect = $pkg->{'Section'} || $src_sect;
	my $prio = $pkg->{'Priority'} || $src_prio;
	my $type = $pkg->{'Package-Type'} ||
	        $pkg->get_custom_field('Package-Type') || 'deb';
	push @pkglist, sprintf('%s %s %s %s', $p, $type, $sect, $prio);
	push(@binarypackages,$p);
	foreach (keys %{$pkg}) {
	    my $v = $pkg->{$_};
            if (m/^Architecture$/) {
                # Gather all binary architectures in one set. 'any' and 'all'
                # are special-cased as they need to be the only ones in the
                # current stanza if present.
                if (debarch_eq($v, 'any') || debarch_eq($v, 'all')) {
                    push(@sourcearch, $v) unless $archadded{$v}++;
                } else {
                    for my $a (split(/\s+/, $v)) {
                        error(_g("`%s' is not a legal architecture string"),
                              $a)
                            unless $a =~ /^[\w-]+$/;
                        error(_g('architecture %s only allowed on its ' .
                                 "own (list for package %s is `%s')"),
                              $a, $p, $a)
                            if $a eq 'any' or $a eq 'all';
                        push(@sourcearch, $a) unless $archadded{$a}++;
                    }
                }
            } elsif (m/^Homepage$/) {
                # Do not overwrite the same field from the source entry
            } else {
                field_transfer_single($pkg, $fields);
            }
	}
    }
    unless (scalar(@pkglist)) {
	error(_g("%s doesn't list any binary package"), $controlfile);
    }
    if (any { $_ eq 'any' } @sourcearch) {
        # If we encounter one 'any' then the other arches become insignificant
        # except for 'all' that must also be kept
        if (any { $_ eq 'all' } @sourcearch) {
            @sourcearch = qw(any all);
        } else {
            @sourcearch = qw(any);
        }
    } else {
        # Minimize arch list, by removing arches already covered by wildcards
        my @arch_wildcards = grep { debarch_is_wildcard($_) } @sourcearch;
        my @mini_sourcearch = @arch_wildcards;
        foreach my $arch (@sourcearch) {
            if (none { debarch_is($arch, $_) } @arch_wildcards) {
                push @mini_sourcearch, $arch;
            }
        }
        @sourcearch = @mini_sourcearch;
    }
    $fields->{'Architecture'} = join(' ', @sourcearch);
    $fields->{'Package-List'} = "\n" . join("\n", sort @pkglist);

    # Scan fields of dpkg-parsechangelog
    foreach (keys %{$changelog}) {
        my $v = $changelog->{$_};

	if (m/^Source$/) {
	    set_source_package($v);
	    $fields->{$_} = $v;
	} elsif (m/^Version$/) {
	    my ($ok, $error) = version_check($v);
            error($error) unless $ok;
	    $fields->{$_} = $v;
	} elsif (m/^Binary-Only$/) {
	    error(_g('building source for a binary-only release'))
	        if $v eq 'yes' and $options{opmode} eq '-b';
	} elsif (m/^Maintainer$/i) {
            # Do not replace the field coming from the source entry
	} else {
            field_transfer_single($changelog, $fields);
	}
    }

    $fields->{'Binary'} = join(', ', @binarypackages);
    # Avoid overly long line by splitting over multiple lines
    if (length($fields->{'Binary'}) > 980) {
	$fields->{'Binary'} =~ s/(.{0,980}), ?/$1,\n/g;
    }

    # Select the format to use
    if (not defined $build_format) {
	if (-e "$dir/debian/source/format") {
	    open(my $format_fh, '<', "$dir/debian/source/format") ||
		syserr(_g('cannot read %s'), "$dir/debian/source/format");
	    $build_format = <$format_fh>;
	    chomp($build_format) if defined $build_format;
	    error(_g('%s is empty'), "$dir/debian/source/format")
		unless defined $build_format and length $build_format;
	    close($format_fh);
	} else {
	    warning(_g('no source format specified in %s, ' .
	               'see dpkg-source(1)'), 'debian/source/format')
		if $options{opmode} eq '-b';
	    $build_format = '1.0';
	}
    }
    $fields->{'Format'} = $build_format;
    $srcpkg->upgrade_object_type(); # Fails if format is unsupported
    # Parse command line options
    $srcpkg->init_options();
    $srcpkg->parse_cmdline_options(@cmdline_options);

    if ($options{opmode} eq '--print-format') {
	print $fields->{'Format'} . "\n";
	exit(0);
    } elsif ($options{opmode} eq '--before-build') {
	$srcpkg->before_build($dir);
	exit(0);
    } elsif ($options{opmode} eq '--after-build') {
	$srcpkg->after_build($dir);
	exit(0);
    } elsif ($options{opmode} eq '--commit') {
	$srcpkg->commit($dir);
	exit(0);
    }

    # Verify pre-requisites are met
    my ($res, $msg) = $srcpkg->can_build($dir);
    error(_g("can't build with source format '%s': %s"), $build_format, $msg) unless $res;

    # Only -b left
    info(_g("using source format `%s'"), $fields->{'Format'});
    run_vendor_hook('before-source-build', $srcpkg);
    # Build the files (.tar.gz, .diff.gz, etc)
    $srcpkg->build($dir);

    # Write the .dsc
    my $dscname = $srcpkg->get_basename(1) . '.dsc';
    info(_g('building %s in %s'), $sourcepackage, $dscname);
    $srcpkg->write_dsc(filename => $dscname,
		       remove => \%remove,
		       override => \%override,
		       substvars => $substvars);
    exit(0);

} elsif ($options{opmode} eq '-x') {

    # Check command line
    unless (scalar(@ARGV)) {
	usageerr(_g('-x needs at least one argument, the .dsc'));
    }
    if (scalar(@ARGV) > 2) {
	usageerr(_g('-x takes no more than two arguments'));
    }
    my $dsc = shift(@ARGV);
    if (-d $dsc) {
	usageerr(_g('-x needs the .dsc file as first argument, not a directory'));
    }

    # Create the object that does everything
    my $srcpkg = Dpkg::Source::Package->new(filename => $dsc,
					    options => \%options);

    # Parse command line options
    $srcpkg->parse_cmdline_options(@cmdline_options);

    # Decide where to unpack
    my $newdirectory = $srcpkg->get_basename();
    $newdirectory =~ s/_/-/g;
    if (@ARGV) {
	$newdirectory = File::Spec->catdir(shift(@ARGV));
	if (-e $newdirectory) {
	    error(_g('unpack target exists: %s'), $newdirectory);
	}
    }

    # Various checks before unpacking
    unless ($options{no_check}) {
        if ($srcpkg->is_signed()) {
            $srcpkg->check_signature();
        } else {
            if ($options{require_valid_signature}) {
                error(_g("%s doesn't contain a valid OpenPGP signature"), $dsc);
            } else {
                warning(_g('extracting unsigned source package (%s)'), $dsc);
            }
        }
        $srcpkg->check_checksums();
    }

    # Unpack the source package (delegated to Dpkg::Source::Package::*)
    info(_g('extracting %s in %s'), $srcpkg->{fields}{'Source'}, $newdirectory);
    $srcpkg->extract($newdirectory);

    exit(0);
}

sub setopmode {
    if (defined($options{opmode})) {
	usageerr(_g('only one of -x, -b or --print-format allowed, and only once'));
    }
    $options{opmode} = $_[0];
}

sub version {
    printf _g("Debian %s version %s.\n"), $Dpkg::PROGNAME, $Dpkg::PROGVERSION;

    print _g('
This is free software; see the GNU General Public License version 2 or
later for copying conditions. There is NO warranty.
');
}

sub usage {
    printf _g(
'Usage: %s [<option>...] <command>')
    . "\n\n" . _g(
'Commands:
  -x <filename>.dsc [<output-dir>]
                           extract source package.
  -b <dir>                 build source package.
  --print-format <dir>     print the source format that would be
                           used to build the source package.
  --commit [<dir> [<patch-name>]]
                           store upstream changes in a new patch.')
    . "\n\n" . _g(
"Build options:
  -c<control-file>         get control info from this file.
  -l<changelog-file>       get per-version info from this file.
  -F<changelog-format>     force changelog format.
  -V<name>=<value>         set a substitution variable.
  -T<substvars-file>       read variables here.
  -D<field>=<value>        override or add a .dsc field and value.
  -U<field>                remove a field.
  -q                       quiet mode.
  -i[<regexp>]             filter out files to ignore diffs of
                             (defaults to: '%s').
  -I[<pattern>]            filter out files when building tarballs
                             (defaults to: %s).
  -Z<compression>          select compression to use (defaults to '%s',
                             supported are: %s).
  -z<level>                compression level to use (defaults to '%d',
                             supported are: '1'-'9', 'best', 'fast')")
    . "\n\n" . _g(
"Extract options:
  --no-copy                don't copy .orig tarballs
  --no-check               don't check signature and checksums before unpacking
  --require-valid-signature abort if the package doesn't have a valid signature")
    . "\n\n" . _g(
'General options:
  -?, --help               show this help message.
      --version            show the version.')
    . "\n\n" . _g(
'More options are available but they depend on the source package format.
See dpkg-source(1) for more info.') . "\n",
    $Dpkg::PROGNAME,
    $Dpkg::Source::Package::diff_ignore_default_regexp,
    join(' ', map { "-I$_" } @Dpkg::Source::Package::tar_ignore_default_pattern),
    compression_get_default(),
    join(' ', compression_get_list()),
    compression_get_default_level();
}
