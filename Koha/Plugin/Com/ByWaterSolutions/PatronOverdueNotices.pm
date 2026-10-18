package Koha::Plugin::Com::ByWaterSolutions::PatronOverdueNotices;

## It's good practive to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

use C4::Overdues qw(parse_overdues_letter);
use Koha::Database;

use open qw(:utf8);

## Here we set our plugin version
our $VERSION = "{VERSION}";
our $MINIMUM_VERSION = "{MINIMUM_VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Patron Overdue Notices',
    author          => 'Kyle M Hall',
    description     => 'Generate and print overdue notices for patrons.',
    date_authored   => '2016-06-20',
    date_updated    => "1900-01-01",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
};

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

## The existance of a 'report' subroutine means the plugin is capable
## of running a report. The difference between a report and a report is
## primarily semantic, but in general any plugin that modifies the
## Koha database should be considered a report
sub report {
    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('submit') ) {
        $self->report_step1();
    }
    else {
        $self->report_step2();
    }

}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ( $self, $args ) = @_;

    return 1;
}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ( $self, $args ) = @_;

    return 1;
}

sub report_step1 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template( { file => 'report-step1.tt' } );

    print $cgi->header();
    print $template->output();
}

sub report_step2 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $branchcode        = scalar $cgi->param('branchcode');
    my $branchcode_field  = scalar $cgi->param('branchcode_field');
    my $days_from         = scalar $cgi->param('days_from');
    my $days_to           = scalar $cgi->param('days_to');
    my $fines_from        = scalar $cgi->param('fines_from');
    my $fines_to          = scalar $cgi->param('fines_to');
    my $patron_cardnumber = scalar $cgi->param('cardnumber');
    my $patron_id         = scalar $cgi->param('borrowernumber');
    my $notice_code       = scalar $cgi->param('notice_code');
    my $filter_issues     = scalar $cgi->param('filter_issues');
    my @categorycodes     = $cgi->multi_param('categorycode');
    my @loststatuses      = $cgi->multi_param('loststatuses');
    my @itemtypes         = $cgi->multi_param('itemtypes');

    my %valid_branchcode_fields = ( holdingbranch => 1, homebranch => 1 );
    $branchcode_field = $valid_branchcode_fields{$branchcode_field} ? $branchcode_field : 'homebranch';

    ( $days_from, $days_to ) = ( $days_to, $days_from )
      if ( $days_to > $days_from );

    my $dbh   = C4::Context->dbh();
    my $query = qq{
        SELECT
            ( SELECT SUM(amountoutstanding) FROM accountlines WHERE borrowernumber = borrowers.borrowernumber ) AS amountoutstanding,
            biblio.title,
            borrowers.zipcode,
            borrowers.address,
            borrowers.address2,
            borrowers.borrowernumber,
            borrowers.cardnumber,
            borrowers.branchcode,
            borrowers.city,
            borrowers.email,
            borrowers.firstname,
            borrowers.surname,
            issues.date_due,
            issues.issue_id,
            issues.issuedate,
            items.barcode,
            items.biblionumber,
            items.holdingbranch,
            items.homebranch,
            items.itemcallnumber,
            items.itemnumber,
            items.price,
            items.replacementprice,
            items.itype,
            items.onloan

FROM   issues
       LEFT JOIN items
              ON ( issues.itemnumber = items.itemnumber )
       LEFT JOIN biblio USING ( biblionumber )
       LEFT JOIN biblioitems USING ( biblioitemnumber )
       LEFT JOIN borrowers USING ( borrowernumber )
WHERE  1
    };

    my @params;

    if ( $days_from && $days_to ) {
        $query .= qq{ AND date_due BETWEEN DATE_SUB(CURDATE(), INTERVAL ? DAY) AND DATE_SUB(CURDATE(), INTERVAL ? DAY) };
        push( @params, $days_from );
        push( @params, $days_to );
    } else {
        $query .= qq{ AND date_due < NOW() };
    }

    if ( $branchcode && $filter_issues ) {
        $query .= qq{ AND items.$branchcode_field = ? };
        push( @params, $branchcode );
    }
    ## FIXME else limit by patron branchcode?

    if (@categorycodes) {
        my $placeholders = join( ',', ('?') x @categorycodes );
        $query .= qq{ AND borrowers.categorycode IN ( $placeholders ) };
        push( @params, @categorycodes );
    }

    if ( $patron_id ) {
        $query .= qq{ AND borrowers.borrowernumber = ? };
        push( @params, $patron_id );
    }
    elsif ( $patron_cardnumber ) {
        $query .= qq{ AND borrowers.cardnumber = ? };
        push( @params, $patron_cardnumber );
    }

    if ( @itemtypes ) {
        my $placeholders = join( ',', ('?') x @itemtypes );
        $query .= qq{ AND items.itype IN ( $placeholders ) };
        push( @params, @itemtypes );
    }

    if ( @loststatuses ) {
        my $placeholders = join( ',', ('?') x @loststatuses );
        $query .= qq{ AND items.itemlost NOT IN ( $placeholders ) };
        push( @params, @loststatuses );
    }

    if ( $fines_from && $fines_to ) {
        $query .= qq{ AND ( SELECT SUM(amountoutstanding) FROM accountlines WHERE borrowernumber = borrowers.borrowernumber ) BETWEEN ? AND ? };
        push( @params, $fines_from, $fines_to );
    } elsif ( $fines_from ) {
        $query .= qq{ AND ( SELECT SUM(amountoutstanding) FROM accountlines WHERE borrowernumber = borrowers.borrowernumber ) >= ? };
        push( @params, $fines_from );
    } elsif ( $fines_to ) {
        $query .= qq{ AND ( SELECT SUM(amountoutstanding) FROM accountlines WHERE borrowernumber = borrowers.borrowernumber ) <= ? };
        push( @params, $fines_to );
    }

    $query .= qq{ ORDER BY surname, firstname, cardnumber };

    my $sth = $dbh->prepare($query);
    $sth->execute(@params);

    my $overdues;
    my @rows;
    while ( my $row = $sth->fetchrow_hashref ) {
        push( @rows, $row );

        my $borrowernumber = $row->{borrowernumber};
        $overdues->{$borrowernumber} ||= [];
        push( @{ $overdues->{$borrowernumber} }, $row );
    }

    my @notices;
    foreach my $borrowernumber ( keys %$overdues ) {
        my $notice = parse_overdues_letter(
            {
                message_transport_type => 'print',
                letter_code            => $notice_code,
                borrowernumber         => $borrowernumber,
                branchcode =>
                  $overdues->{$borrowernumber}->[0]->{branchcode},
                items      => $overdues->{$borrowernumber},
                substitute => {
                    count => scalar @{ $overdues->{$borrowernumber} },
                },
            }
        );

        push( @notices, $notice );
    }

    my $template = $self->get_template( { file => 'report-step2.tt' } );
    $template->param(
        notices  => \@notices,
        rows     => \@rows,
        overdues => $overdues,
    );

    print $cgi->header();
    print $template->output();
}

1;
