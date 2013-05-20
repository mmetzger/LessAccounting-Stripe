require 'sinatra'
require 'sinatra/reloader'
require 'net/http'
require 'uri'
require 'json'
require 'stripe'
require 'pp'

configure do
  set :baseurl, 'https://flexiblecreations.lessaccounting.com/'
  set :company_name, 'Flexible Creations, LLC'
  set :lauser, ENV['LESSACCOUNTING_USER'] 
  set :lapass, ENV['LESSACCOUNTING_PASS']
  set :lakey, ENV['LESSACCOUNTING_APIKEY'] 

  set :publishable_key, ENV['STRIPE_PK'] 
  set :secret_key, ENV['STRIPE_SK'] 

  Stripe.api_key = settings.secret_key
end

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
