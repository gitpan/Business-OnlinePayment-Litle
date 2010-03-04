package Business::OnlinePayment::Litle;

use warnings;
use strict;

use Business::OnlinePayment;
use Business::OnlinePayment::HTTPS;
use Business::OnlinePayment::Litle::ErrorCodes '%ERRORS';
use vars qw(@ISA $me $DEBUG $VERSION);
use XML::Writer;
use XML::Simple;
use Tie::IxHash;
use Business::CreditCard qw(cardtype);
use Data::Dumper;

@ISA     = qw(Business::OnlinePayment::HTTPS);
$me      = 'Business::OnlinePayment::Litle';
$DEBUG   = 0;
$VERSION = '0.3';

=head1 NAME

Business::OnlinePayment::Litle - Litle & Co. Backend for Business::OnlinePayment

=head1 VERSION

Version 0.2

=cut

=head1 SYNOPSIS

This is a plugin for the Business::OnlinePayment interface.  Please refer to that docuementation for general usage, and here for Litle specific usage.

In order to use this module, you will need to have an account set up with Litle & Co. L<http://www.litle.com/>


  use Business::OnlinePayment;
  my $tx = Business::OnlinePayment->new(
     "Litle",
     default_Origin => 'NEW',
  );

  $tx->content(
      type           => 'CC',
      login          => 'testdrive',
      password       => '123qwe',
      action         => 'Normal Authorization',
      description    => 'FOO*Business::OnlinePayment test',
      amount         => '49.95',
      customer_id    => 'tfb',
      name           => 'Tofu Beast',
      address        => '123 Anystreet',
      city           => 'Anywhere',
      state          => 'UT',
      zip            => '84058',
      card_number    => '4007000000027',
      expiration     => '09/02',
      cvv2           => '1234', #optional
      invoice_number => '54123',
  );
  $tx->submit();

  if($tx->is_success()) {
      print "Card processed successfully: ".$tx->authorization."\n";
  } else {
      print "Card was rejected: ".$tx->error_message."\n";
  }

=head1 METHODS AND FUNCTIONS

See L<Business::OnlinePayment> for the complete list. The following methods either override the methods in L<Business::OnlinePayment> or provide additional functions.  

=head2 result_code

Returns the response error code.

=head2 error_message

Returns the response error description text.

=head2 server_response

Returns the complete response from the server.

=head1 Handling of content(%content) data:

=head2 action

The following actions are valid

  normal authorization
  authorization only
  post authorization
  credit
  void

=head1 Litle specific data

=head2 Fields

Mostdata fields nto part of the BOP standard can be added to the content hash directly, and will be used

=head2 Products

Part of the enhanced data for level III Interchange rates

    products        =>  [
    {   description =>  'First Product',
        sku         =>  'sku',
        quantity    =>  1,
        units       =>  'Months',
        amount      =>  500,  ## currently I don't reformat this, $5.00
        discount    =>  0,
        code        =>  1,
        cost        =>  500,
    },
    {   description =>  'Second Product',
        sku         =>  'sku',
        quantity    =>  1,
        units       =>  'Months',
        amount      =>  1500,
        discount    =>  0,
        code        =>  2,
        cost        =>  500,
    }

    ],

=cut

=head1 SPECS

Currently uses the Litle XML specifications version 7.2

=head1 TESTING

In order to run the provided test suite, you will first need to apply and get your account setup with Litle.  Then you can use the test account information they give you to run the test suite.  The scripts will look for three environment variables to connect: BOP_USERNAME, BOP_PASSWORD, BOP_MERCHANTID

Currently the description field also uses a fixed descriptor.  This will possibly need to be changed based on your arrangements with Litle.

=head1 FUNCTIONS

=head2 _info

Return the introspection hash for BOP 3.x

=cut

sub _info {
    return {
        info_compat         =>  '0.01',
        gateway_name        =>  'Litle',
        gateway_url         =>  'http://www.litle.com',
        module_version      =>  $VERSION,
        supported_types     =>  [ 'CC' ],
        supported_actions   =>  {
            CC  =>  [
                'Normal Authorization',
                'Post Authorization',
                'Authorization Only',
                'Credit',
                'Void',
                ],
            },
    }
}

=head2 set_defaults

=cut

sub set_defaults {
    my $self = shift;
    my %opts = @_;

    $self->server('cert.litle.com')         unless $self->server;
    $self->port('443')                      unless $self->port;
    $self->path('/vap/communicator/online') unless $self->path;

    if ( $opts{debug} ) {
        $self->debug( $opts{debug} );
        delete $opts{debug};
    }

    ## load in the defaults
    my %_defaults = ();
    foreach my $key ( keys %opts ) {
        $key =~ /^default_(\w*)$/ or next;
        $_defaults{$1} = $opts{$key};
        delete $opts{$key};
    }

    $self->build_subs(
        qw( order_number md5 avs_code cvv2_response
          cavv_response api_version xmlns failure_status
          )
    );

    $self->api_version('7.2')                   unless $self->api_version;
    $self->xmlns('http://www.litle.com/schema') unless $self->xmlns;
}

=head2 map_fields

=cut

sub map_fields {
    my ($self) = @_;

    my %content = $self->content();

    my $action  = lc( $content{'action'} );
    my %actions = (
        'normal authorization' => 'sale',
        'authorization only'   => 'authorization',
        'post authorization'   => 'capture',
        'void'                 => 'void',
        'credit'               => 'credit',

        # AVS ONLY
        # Capture Given
        # Force Capture
        #
    );
    $content{'TransactionType'} = $actions{$action} || $action;

    $content{'company_phone'} =~ s/\D//g;

    my $type_translate = {
        'VISA card'                   => 'VI',
        'MasterCard'                  => 'MC',
        'Discover card'               => 'DI',
        'American Express card'       => 'AX',
        'Diner\'s Club/Carte Blanche' => 'DI',
        'JCB'                         => 'DI',
        'China Union Pay'             => 'DI',
    };

    $content{'card_type'} =
         $type_translate->{ cardtype( $content{'card_number'} ) }
      || $content{'type'};

    if ( $content{recurring_billing} && $content{recurring_billing} eq 'YES' ) {
        $content{'orderSource'} = 'recurring';
    }
    else {
        $content{'orderSource'} = 'ecommerce';
    }
    $content{'customerType'} =
      $content{'orderSource'} eq 'recurring'
      ? 'Existing'
      : 'New';    # new/Existing

    $content{'expiration'} =~ s/\D+//g;

    $content{'deliverytype'} = 'SVC';

    # stuff it back into %content
    if ( $content{'products'} && ref( $content{'products'} ) eq 'ARRAY' ) {
        my $count = 1;
        foreach ( @{ $content{'products'} } ) {
            $_->{'itemSequenceNumber'} = $count++;
        }
    }
    $self->content(%content);
}

sub submit {
    my ($self) = @_;

    $self->is_success(0);
    $self->map_fields;
    my %content = $self->content();
    my $action  = $content{'TransactionType'};

    my @required_fields = qw(action login type);

    $self->required_fields(@required_fields);
    my $post_data;
    my $writer = new XML::Writer(
        OUTPUT      => \$post_data,
        DATA_MODE   => 1,
        DATA_INDENT => 2,
        ENCODING    => 'utf8',
    );

    # for tabbing
    # clean up the amount to the required format
    my $amount;
    if ( defined( $content{amount} ) ) {
        $amount = sprintf( "%.2f", $content{amount} );
        $amount =~ s/\.//g;
    }

    tie my %billToAddress, 'Tie::IxHash', $self->revmap_fields(
        name         => 'name',
        email        => 'email',
        addressLine1 => 'address',
        city         => 'city',
        state        => 'state',
        zip          => 'zip',
        country      => 'country'
        , #TODO: will require validation to the spec, this field wont' work as is
        phone => 'phone',
    );

    tie my %shipToAddress, 'Tie::IxHash', $self->revmap_fields(
        name         => 'ship_name',
        email        => 'ship_email',
        addressLine1 => 'ship_address',
        city         => 'ship_city',
        state        => 'ship_state',
        zip          => 'ship_zip',
        country      => 'ship_country'
        , #TODO: will require validation to the spec, this field wont' work as is
        phone => 'ship_phone',
    );

    tie my %authentication, 'Tie::IxHash',
      $self->revmap_fields(
        user     => 'login',
        password => 'password',
      );

    tie my %customerinfo, 'Tie::IxHash',
      $self->revmap_fields( customerType => 'customerType', );

    my $description = substr( $content{'description'}, 0, 25 );    # schema req

    tie my %custombilling, 'Tie::IxHash',
      $self->revmap_fields(
        phone      => 'company_phone',
        descriptor => \$description,
      );

    ## loop through product list and generate linItemData for each
    #
    my @products = ();
    foreach my $prod ( @{ $content{'products'} } ) {
        tie my %lineitem, 'Tie::IxHash',
          $self->revmap_fields(
            content              => $prod,
            itemSequenceNumber   => 'itemSequenceNumber',
            itemDescription      => 'description',
            productCode          => 'code',
            quantity             => 'quantity',
            unitOfMeasure        => 'units',
            taxAmount            => 'tax',
            lineItemTotal        => 'amount',
            lineItemTotalWithTax => 'totalwithtax',
            itemDiscountAmount   => 'discount',
            commodityCode        => 'commoditycode',
            unitCost             => 'cost',
          );
        push @products, \%lineitem;
    }

    #
    #
    tie my %enhanceddata, 'Tie::IxHash', $self->revmap_fields(
        orderDate              => 'orderdate',
        salesTax               => 'salestax',
        invoiceReferenceNumber => 'invoice_number',    ##
        lineItemData           => \@products,
        customerReference      => 'po_number',
    );

    tie my %card, 'Tie::IxHash', $self->revmap_fields(
        type               => 'card_type',
        number             => 'card_number',
        expDate            => 'expiration',
        cardValidationNum  => 'cvv2',
        cardAuthentication => '3ds',          # is this what we want to name it?
    );

    tie my %cardholderauth, 'Tie::IxHash',
      $self->revmap_fields(
        authenticationValue         => '3ds',
        authenticationTransactionId => 'visaverified',
        customerIpAddress           => 'ip',
        authenticatedByMerchant     => 'authenticated',
      );

    my %req;

    if (   $action eq 'sale'
        || $action eq 'authorization' )
    {
        tie %req, 'Tie::IxHash', $self->revmap_fields(
            orderId       => 'invoice_number',
            amount        => \$amount,
            orderSource   => 'orderSource',
            customerInfo  => \%customerinfo,
            billToAddress => \%billToAddress,
            shipToAddress => \%shipToAddress,
            card          => \%card,
            #cardholderAuthentication    =>  \%cardholderauth,
            customBilling => \%custombilling,
            enhancedData  => \%enhanceddata,
        );
    }
    elsif ( $action eq 'capture' ) {
        push @required_fields, qw( order_number amount );
        tie %req, 'Tie::IxHash',
          $self->revmap_fields(
            litleTxnId   => 'order_number',
            amount       => \$amount,
            enhancedData => \%enhanceddata,
          );
    }
    elsif ( $action eq 'credit' ) {
        push @required_fields, qw( order_number amount );
        tie %req, 'Tie::IxHash', $self->revmap_fields(
            litleTxnId    => 'order_number',
            amount        => \$amount,
            customBilling => \%custombilling,
            enhancedData  => \%enhanceddata,

            #bypassVelocityCheck => Not supported yet
        );
    }
    elsif ( $action eq 'void' ) {
        push @required_fields, qw( order_number );
        tie %req, 'Tie::IxHash',
          $self->revmap_fields( litleTxnId => 'order_number', );
    }

    $self->required_fields(@required_fields);

    #warn Dumper( \%req ) if $DEBUG;
    ## Start the XML Document, parent tag
    $writer->xmlDecl();
    $writer->startTag(
        "litleOnlineRequest",
        version    => $self->api_version,
        xmlns      => $self->xmlns,
        merchantId => $content{'merchantid'},
    );

    $self->_xmlwrite( $writer, 'authentication', \%authentication );
    $writer->startTag(
        $content{'TransactionType'},
        id          => $content{'invoice_number'},
        reportGroup => "Test",
        customerId  => "1"
    );
    foreach ( keys(%req) ) {
        $self->_xmlwrite( $writer, $_, $req{$_} );
    }

    $writer->endTag( $content{'TransactionType'} );
    $writer->endTag("litleOnlineRequest");
    $writer->end();
    ## END XML Generation

    my ( $page, $server_response, %headers ) = $self->https_post($post_data);
    $self->{'_post_data'} = $post_data;
    warn $self->{'_post_data'} if $DEBUG;

    warn Dumper $page, $server_response, \%headers if $DEBUG;

    my $response = {};
    if ( $server_response =~ /^200/ ) {
        $response = XMLin($page);
        if ( exists( $response->{'response'} ) && $response->{'response'} == 1 )
        {
            ## parse error type error
            print Dumper( $response, $self->{'_post_data'} );
            $self->error_message( $response->{'message'} );
            return;
        }
        else {
            $self->error_message(
                $response->{ $content{'TransactionType'} . 'Response' }
                  ->{'message'} );
        }
    } else {
        die "CONNECTION FAILURE: $server_response";
    }
    warn Dumper($response) if $DEBUG;

    ## Set up the data:
    my $resp = $response->{ $content{'TransactionType'} . 'Response' };
    $self->order_number( $resp->{'litleTxnId'} || '' );
    $self->result_code( $resp->{'response'}    || '' );
    $self->authorization( $resp->{'authCode'}  || '' );
    $self->cvv2_response( $resp->{'fraudResult'}->{'cardValidationResult'}
          || '' );
    $self->avs_code( $resp->{'fraudResult'}->{'avsResult'} || '' );

    $self->is_success( $self->result_code() eq '000' ? 1 : 0 );

    ##Failure Status for 3.0 users
    if( ! $self->is_success ) {
        my $f_status = $ERRORS{ $self->result_code }->{'failure'}
        ? $ERRORS{ $self->result_code }->{'failure'}
        : 'decline';
        $self->failure_status( $f_status );
    }

    unless ( $self->is_success() ) {
        unless ( $self->error_message() ) {
            $self->error_message( "(HTTPS response: $server_response) "
                  . "(HTTPS headers: "
                  . join( ", ", map { "$_ => " . $headers{$_} } keys %headers )
                  . ") "
                  . "(Raw HTTPS content: $page)" );
        }
    }

}

sub revmap_fields {
    my $self = shift;
    tie my (%map), 'Tie::IxHash', @_;
    my %content;
    if ( $map{'content'} && ref( $map{'content'} ) eq 'HASH' ) {
        %content = %{ delete( $map{'content'} ) };
    }
    else {
        %content = $self->content();
    }

    map {
        my $value;
        if ( ref( $map{$_} ) eq 'HASH' ) {
            $value = $map{$_} if ( keys %{ $map{$_} } );
        }
        elsif ( ref( $map{$_} ) eq 'ARRAY' ) {
            $value = $map{$_};
        }
        elsif ( ref( $map{$_} ) ) {
            $value = ${ $map{$_} };
        }
        elsif ( exists( $content{ $map{$_} } ) ) {
            $value = $content{ $map{$_} };
        }

        if ( defined($value) ) {
            ( $_ => $value );
        }
        else {
            ();
        }
    } ( keys %map );
}

sub _xmlwrite {
    my ( $self, $writer, $item, $value ) = @_;
    if ( ref($value) eq 'HASH' ) {
        my $attr = $value->{'attr'} ? $value->{'attr'} : {};
        $writer->startTag( $item, %{$attr} );
        foreach ( keys(%$value) ) {
            next if $_ eq 'attr';
            $self->_xmlwrite( $writer, $_, $value->{$_} );
        }
        $writer->endTag($item);
    }
    elsif ( ref($value) eq 'ARRAY' ) {
        foreach ( @{$value} ) {
            $self->_xmlwrite( $writer, $item, $_ );
        }
    }
    else {
        $writer->startTag($item);
        $writer->characters($value);
        $writer->endTag($item);
    }
}

=head1 AUTHOR

Jason Hall, C<< <jayce at lug-nut.com> >>

=head1 UNIMPLEMENTED

Cretain features are not yet implemented (no current personal business need), though the capability of support is there, and the test data for the verification suite is there.
   
    Force Capture
    Capture Given Auth
    3DS
    billMeLater
    Credit against non-litle transaction

=head1 BUGS

Please report any bugs or feature requests to C<bug-business-onlinepayment-litle at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Business-OnlinePayment-Litle>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

You may also add to the code via github, at L<http://github.com/Jayceh/Business--OnlinePayment--Litle.git>


=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Business::OnlinePayment::Litle


You can also look for information at:

L<http://www.litle.com/>

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Business-OnlinePayment-Litle>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Business-OnlinePayment-Litle>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Business-OnlinePayment-Litle>

=item * Search CPAN

L<http://search.cpan.org/dist/Business-OnlinePayment-Litle/>

=back


=head1 ACKNOWLEDGEMENTS

Heavily based on Jeff Finucane's l<Business::OnlinePayment::IPPay> because it also required dynamically writing XML formatted docs to a gateway.

=head1 COPYRIGHT & LICENSE

Copyright 2009 Jason Hall.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=back


=head1 SEE ALSO

perl(1). L<Business::OnlinePayment>


=cut

1;    # End of Business::OnlinePayment::Litle