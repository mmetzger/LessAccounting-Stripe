#
# Basic LessAccounting <-> Stripe integration using API
#
# Utilizes LessAccounting Invoice calls to get list of invoices, Payments API to post payments
# Stripe "blue-button" popup used to charge cards
#
# Mike Metzger, mike@flexiblecreations.com
# 2013-05-10
#

require 'sinatra'
require 'sinatra/reloader'
require 'net/http'
require 'uri'
require 'json'
require 'stripe'
require 'pp'

configure do
  set :baseurl, 'https://flexiblecreations.lessaccounting.com/'		# Change to your LessAccounting URL
  set :company_name, 'Flexible Creations, LLC'				# Change to your Company Name / Description,
									#  appears in the Stripe popup

  set :lauser, ENV['LESSACCOUNTING_USER'] 				# LessAccounting User
  set :lapass, ENV['LESSACCOUNTING_PASS']				# LessAccounting Password
  set :lakey, ENV['LESSACCOUNTING_APIKEY'] 				# LessAccounting API Key

  set :publishable_key, ENV['STRIPE_PK'] 				# Stripe Publishable Key (Test / Live)
  set :secret_key, ENV['STRIPE_SK'] 					# Stripe Secret Key (Test / Live)

  Stripe.api_key = settings.secret_key
end

#
# Shows a basic list of Unpaid invoices.  This is mainly for testing, I would suggest creating a different method
# of searching for the invoice in question (may not want invoices browseable between customers.)
#
get '/unpaid' do
  uri = URI.parse(settings.baseurl + "invoices/unpaid.json?api_key=" + settings.lakey)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  request = Net::HTTP::Get.new(uri.request_uri, "Accept" => 'application/json')
  request.basic_auth(settings.lauser, settings.lapass)
  rsp = http.request(request)

  @title = "Unpaid Invoices"
  @invoices = JSON.parse(rsp.body)
  erb :index 
end

#
# Test method to show paid invoices - do not use in production
#
get '/paid' do
  uri = URI.parse(settings.baseurl + "invoices/paid.json?api_key=" + settings.lakey)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  request = Net::HTTP::Get.new(uri.request_uri, "Accept" => 'application/json')
  request.basic_auth(settings.lauser, settings.lapass)
  rsp = http.request(request)

  @title = "Paid Invoices"
  @invoices = JSON.parse(rsp.body)
  erb :index 
end

# 
# This is the starting method for generating a Stripe charge.  
#
# 1) Invoice ID is passed as parameter and used in the invoices API call to get detail info on the Invoice.
# 2) The total due is calculated (invoice total - payment totals)
# 3) If the total due is zero, no charge is made
# 4) If there is a balance due, a Stripe popup is created using the company details and invoice details
# 5) If the Stripe card is valid, the Stripe.js script forwards to the /charge URL endpoint with the Stripe Token and
#    appropriate details.
# 6) If the card fails, an option to try again appears along with an error message.  Note that some Stripe errors render their
#    own messages and require further customization.
#
get '/pay/:invoiceid' do
  @invoiceid = params[:invoiceid]
  uri = URI.parse(settings.baseurl + "invoices/" + @invoiceid + ".json?api_key=" + settings.lakey)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  request = Net::HTTP::Get.new(uri.request_uri, "Accept" => 'application/json')
  request.basic_auth(settings.lauser, settings.lapass)
  rsp = http.request(request)
  
  @invoicedetails = JSON.parse(rsp.body)

  @paymentdue = @invoicedetails["total"] - @invoicedetails["payment_total"]
  if @paymentdue == 0
    @title = "Invoice " + @invoicedetails["reference_name_number"]
    erb :paidinfull
  else
    @title = "Pay invoice " + @invoicedetails["reference_name_number"]
    erb :pay
  end
end

#
# This method actually charges the user's card using the Stripe token information.
# 
# 1) Stripe token and invoice details are taken as parameters.  Note that Stripe requires charges in cents 
#    (ie, $1500.00 == 150000)
# 2) A Stripe.charge is created with the details.
# 3) Once charge is successful, a call to the LessAccounting Payments API is made to create the payment with the
#    appropriate details.  Note that the Payments API call uses querystring values, not POST data.  
# 4) If the POST returns a 201, the payment successful page appears with a thank you note.
# 5) If there is an issue anywhere along the way, an error page appears.
#
# TODO: Error handling is almost non-existant.  Need to separate the API calls out a bit more - if Stripe fails, throw proper
#       error.  If Payments API call fails, possibly refund Stripe or try Payments API again.
#
post '/charge' do
  t = Time.now
  pp params

  @dollars, @cents = params[:invoiceamount].split('.')
  @amount = @dollars.to_i * 100 + @cents.to_i
  @email = params[:email]
  @invoicenum = params[:invoicenum]
  @invoiceid = params[:invoiceid]
  
  pp "Charging: " + @amount.to_s

  begin
    charge = Stripe::Charge.create(
      :amount => @amount,
      :description => "Payment for invoice " + @invoicenum,
      :currency => 'usd',
      :card => params[:stripeToken]
    )

    uri = URI.parse(settings.baseurl + "payments.json?api_key=" + settings.lakey + "&payment[amount]=" + @dollars + '.%.2d' % @cents.to_i + "&payment[invoice_id]=" + @invoiceid + "&payment[date]=" + Time.now.strftime("%Y-%m-%d") + "&payment[payment_type]=regular%20income") 
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(uri.request_uri, "Accept" => 'application/json')
    request.basic_auth(settings.lauser, settings.lapass)
    rsp = http.request(request)

    pp rsp

    if rsp.code == "201"
      @paymentdetails = JSON.parse(rsp.body)
      pp @paymentdetails
      pp "Card charged"

      @title = 'Payment received'

      erb :charge  
    else
      pp rsp.code
      @title = 'Issue with payment'

      @responsebody = rsp.body
      erb :paymentissue
    end 
  rescue => e
    pp e.message
  end

end

__END__

@@layout

<html>
  <head>
    <title><%= @title %></title>
  </head>
  <body>
    <%= yield %>
  </body>
</html>

@@index

<h1><%= @title %></h1>
<table>
<tr>
<td></td><td>Invoice Number</td><td>Due Date</td><td>Amount</td>
</tr>
<% @invoices.each do |invoice| %>
<tr>
<td><a href="/pay/<%= invoice["id"] %>">Pay Now</a></td><td><%= invoice["reference_name_number"] %></td><td><%= invoice["due_on"] %></td><td><%= invoice["total"] %></td>
</tr>
<% end %>
</table>

@@pay

<h1><%= @title %></h1>
<table>
<tr><td>Invoice Total</td><td>&nbsp;</td><td><%=@invoicedetails["total"] %></td></tr>
<tr><td>Payments made</td><td>&nbsp;</td><td><%=@invoicedetails["payment_total"] %></td></tr>
<tr><td>Amount owed</td><td>&nbsp;</td><td><%=@paymentdue %></td></tr>
</table>
<form action="/charge" method="post" class="payment">
  <article>
    <!-- <label class="invoicenumber">
      <span>Invoice: <%= @invoicedetails["reference_name_number"] %></span>
    </label>
    <label class="amount">
      <span>Amount: $<%= @paymentdue %></span>
    </label> -->
    <input type="hidden" name="invoiceid" value="<%= @invoicedetails["id"] %>" />
    <input type="hidden" name="invoicenum" value="<%= @invoicedetails["reference_name_number"] %>" />
    <input type="hidden" name="invoiceamount" value="<%= @paymentdue %>" />
    <p /> 
    <label class="email">
       <span>Please enter your email address: 
          <input type="text" name="email" length=40 />
       </span>
    </label>
    <p />
    <script src="https://checkout.stripe.com/v2/checkout.js" class="stripe-button"
      data-key="<%= settings.publishable_key %>"
      data-amount="<%= @paymentdue * 100 %>"
      data-name="<%= settings.company_name %>"
      data-description="Payment for Invoice <%=@invoicedetails["reference_name_number"] %>">
    </script>


@@charge

<h1><%= @title %></h1>
<p>A payment in the amount of $<%= @dollars + sprintf('.%.2d', @cents) %> has been applied to invoice <%= @invoicenum %>.</p>

<p>Thank you for your business!</p>
    
@@paymentissue

<h1><%= @title %></h1>
<p>Unfortunately there was a problem with your payment.</p>
<p><%= @responsebody %></p>
<p>Please try your payment again or contact us with any questions>/p>
<a href="/pay/<%= @invoiceid %>">Try Payment Again</a>

@@paidinfull

<h1><%= @title %></h1>
<p>This invoice is paid in full.  Thank you for verifying it has been paid.</p>
