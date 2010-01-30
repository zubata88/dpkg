# Copyright © 2010 Raphaël Hertzog <hertzog@debian.org>
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

package Dpkg::Compression;

use strict;
use warnings;

our $VERSION = "1.00";

use Dpkg::ErrorHandling;
use Dpkg::Gettext;

use base qw(Exporter);
our @EXPORT = qw($compression_re_file_ext compression_get_list
		 compression_is_supported compression_get_property
		 compression_guess_from_filename
		 compression_get_default compression_set_default
		 compression_get_default_level
		 compression_set_default_level
		 compression_is_valid_level);

=head1 NAME

Dpkg::Compression - simple database of available compression methods

=head1 DESCRIPTION

This modules provides a few public funcions and a public regex to
interact with the set of supported compression methods.

=head1 EXPORTED VARIABLES

=over 4

=cut

my $COMP = {
    "gzip" => {
	"file_ext" => "gz",
	"comp_prog" => [ "gzip" ],
	"decomp_prog" => [ "gunzip" ],
    },
    "bzip2" => {
	"file_ext" => "bz2",
	"comp_prog" => [ "bzip2" ],
	"decomp_prog" => [ "bunzip2" ],
    },
    "lzma" => {
	"file_ext" => "lzma",
	"comp_prog" => [ "lzma" ],
	"decomp_prog" => [ "unlzma" ],
    },
    "xz" => {
	"file_ext" => "xz",
	"comp_prog" => [ "xz" ],
	"decomp_prog" => [ "unxz" ],
    },
};

our $default_compression = "gzip";
our $default_compression_level = 9;

=item $compression_re_file_ext

A regex that matches a file extension of a file compressed with one of the
supported compression methods.

=back

=cut

my $regex = join "|", map { $_->{"file_ext"} } values %$COMP;
our $compression_re_file_ext = qr/(?:$regex)/;

=head1 EXPORTED FUNCTIONS

=over 4

=item my @list = compression_get_list()

Returns a list of supported compression methods (sorted alphabetically).

=cut

sub compression_get_list {
    return sort keys %$COMP;
}

=item compression_is_supported($comp)

Returns a boolean indicating whether the give compression method is
known and supported.

=cut

sub compression_is_supported {
    return exists $COMP->{$_[0]};
}

=item compression_get_property($comp, $property)

Returns the requested property of the compression method. Returns undef if
either the property or the compression method doesn't exist. Valid
properties currently include "file_ext" for the file extension,
"comp_prog" for the name of the compression program and "decomp_prog" for
the name of the decompression program.

=cut

sub compression_get_property {
    my ($comp, $property) = @_;
    return undef unless compression_is_supported($comp);
    return $COMP->{$comp}{$property} if exists $COMP->{$comp}{$property};
    return undef;
}

=item compression_guess_from_filename($filename)

Returns the compression method that is likely used on the indicated
filename based on its file extension.

=cut

sub compression_guess_from_filename {
    my $filename = shift;
    foreach my $comp (compression_get_list()) {
	my $ext = compression_get_property($comp, "file_ext");
        if ($filename =~ /^(.*)\.\Q$ext\E$/) {
	    return $comp;
        }
    }
    return undef;
}

=item my $comp = compression_get_default()

Return the default compression method. It's "gzip" unless
C<compression_set_default> has been used to change it.

=item compression_set_default($comp)

Change the default compression methode. Errors out if the
given compression method is not supported.

=cut

sub compression_get_default {
    return $default_compression;
}

sub compression_set_default {
    my ($method) = @_;
    error(_g("%s is not a supported compression"), $method)
            unless compression_is_supported($method);
    $default_compression = $method;
}

=item my $level = compression_get_default_level()

Return the default compression level used when compressing data. It's "9"
unless C<compression_set_default_level> has been used to change it.

=item compression_set_default_level($level)

Change the default compression level. Errors out if the
level is not valid (see C<compression_is_valid_level>).
either a number between 1 and 9 or "fast"
or "best".

=cut

sub compression_get_default_level {
    return $default_compression_level;
}

sub compression_set_default_level {
    my ($level) = @_;
    error(_g("%s is not a compression level"), $level)
            unless compression_is_valid_level($level);
    $default_compression_level = $level;
}

=item compression_is_valid_level($level)

Returns a boolean indicating whether $level is a valid compression level
(it must be either a number between 1 and 9 or "fast" or "best")

=cut

sub compression_is_valid_level {
    my ($level) = @_;
    return $level =~ /^([1-9]|fast|best)$/;
}

=back

=head1 AUTHOR

Raphaël Hertzog <hertzog@debian.org>.

=cut

1;
