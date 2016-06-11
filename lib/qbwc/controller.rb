require 'wash_out/version'
include WashOut

module QBWC
  module Controller

    AUTHENTICATE_NOT_VALID_USER = 'nvu'
    AUTHENTICATE_NO_WORK = 'none'

    def self.included(base)
      base.class_eval do
        include WashOut::SOAP
        skip_before_filter :_parse_soap_parameters, :_authenticate_wsse, :_map_soap_parameters, :only => :qwc
        before_filter :get_session, :except => [:qwc, :authenticate, :_generate_wsdl]
        after_filter :save_session, :except => [:qwc, :authenticate, :_generate_wsdl, :close_connection, :connection_error]

        # wash_out changed the format of app/views/wash_with_soap/rpc/response.builder in commit
        # https://github.com/inossidabile/wash_out/commit/24a77f4a3d874562732c6e8c3a30e8defafea7cb
        wash_out_xml_namespace = (Gem::Version.new(WashOut::VERSION) < Gem::Version.new('0.9.1') ? 'tns:' : '')

        soap_action 'serverVersion', :to => :server_version,
                    :return => {'tns:serverVersionResult' => :string},
                    :response_tag => "#{wash_out_xml_namespace}serverVersionResponse"

        soap_action 'clientVersion', :to => :client_version,
                    :args   => {:strVersion => :string},
                    :return => {'tns:clientVersionResult' => :string},
                    :response_tag => "#{wash_out_xml_namespace}clientVersionResponse"

        soap_action 'authenticate',
                    :args   => {:strUserName => :string, :strPassword => :string},
                    :return => {'tns:authenticateResult' => StringArray},
                    :response_tag => "#{wash_out_xml_namespace}authenticateResponse"

        soap_action 'sendRequestXML', :to => :send_request,
                    :args   => {:ticket => :string, :strHCPResponse => :string, :strCompanyFilename => :string, :qbXMLCountry => :string, :qbXMLMajorVers => :string, :qbXMLMinorVers => :string},
                    :return => {'tns:sendRequestXMLResult' => :string},
                    :response_tag => "#{wash_out_xml_namespace}sendRequestXMLResponse"

        soap_action 'receiveResponseXML', :to => :receive_response,
                    :args   => {:ticket => :string, :response => :string, :hresult => :string, :message => :string},
                    :return => {'tns:receiveResponseXMLResult' => :integer},
                    :response_tag => "#{wash_out_xml_namespace}receiveResponseXMLResponse"

        soap_action 'closeConnection', :to => :close_connection,
                    :args   => {:ticket => :string},
                    :return => {'tns:closeConnectionResult' => :string},
                    :response_tag => "#{wash_out_xml_namespace}closeConnectionResponse"

        soap_action 'connectionError', :to => :connection_error,
                    :args   => {:ticket => :string, :hresult => :string, :message => :string},
                    :return => {'tns:connectionErrorResult' => :string},
                    :response_tag => "#{wash_out_xml_namespace}connectionErrorResponse"

        soap_action 'getLastError', :to => :get_last_error,
                    :args   => {:ticket => :string},
                    :return => {'tns:getLastErrorResult' => :string},
                    :response_tag => "#{wash_out_xml_namespace}getLastErrorResponse"
      end
    end

    def qwc
      # Optional tag
      @username = SecureRandom.urlsafe_base64(24)
      if !current_user.nil?
        @user_id = current_user.id
      end
      qbd_client = QbdClient.find_by(client_id: session[:client_id])
      if qbd_client.nil?
        qbd_client = QbdClient.new(client_id: session[:client_id], username: @username, user_id: @user_id)
      else
        qbd_client.username = @username
        qbd_client.user_id = @user_id
      end
      if qbd_client.save
        qbd_client.client.update_attributes(integrations: true, integration_software: "qbd")
        import_customers(@username, session[:client_id])
        import_vendors(@username, session[:client_id])
           
        scheduler_block = ''
        if !QBWC.minutes_to_run.nil?
        scheduler_block = <<SB
   <Scheduler>
      <RunEveryNMinutes>#{QBWC.minutes_to_run}</RunEveryNMinutes>
   </Scheduler>
SB
        end

        qwc = <<QWC
<QBWCXML>
   <AppName>#{app_name}</AppName>
   <AppID></AppID>
   <AppURL>#{qbwc_action_url(:only_path => false)}</AppURL>
   <AppDescription>Quickbooks integration</AppDescription>
   <AppSupport>#{QBWC.support_site_url || root_url(:protocol => 'https://')}</AppSupport>
   <UserName>#{@username || QBWC.username}</UserName>
   <OwnerID>#{QBWC.owner_id}</OwnerID>
   <FileID>{#{file_id}}</FileID>
   <QBType>QBFS</QBType>
   <Style>Document</Style>
   #{scheduler_block}
</QBWCXML>
QWC
        send_data qwc, :filename => "#{@filename || Rails.application.class.parent_name}.qwc", :content_type => 'application/x-qwc'
      end
    end

    class StringArray < WashOut::Type
      map "tns:string" => [:string]
    end

    def server_version
      render :soap => {"tns:serverVersionResult" => server_version_response}
    end

    def client_version
      render :soap => {"tns:clientVersionResult" => check_client_version}
    end

    def authenticate
      username = params[:strUserName]
      password = params[:strPassword]
      #if !QBWC.authenticator.nil?
      #  company_file_path = QBWC.authenticator.call(username, password)
      #elsif username == QBWC.username && password == QBWC.password
      #  company_file_path = QBWC.company_file_path
      #else
      #  company_file_path = nil
      #end
      if params[:strPassword] == "accounting"
        company_file_path = ""
      end
      ticket = nil
      if company_file_path.nil?
        QBWC.logger.info "Authentication of user '#{username}' failed."
        company_file_path = AUTHENTICATE_NOT_VALID_USER
      else
        ticket = QBWC.storage_module::Session.new(username, company_file_path).ticket
        session = get_session(ticket)

        if !QBWC.pending_jobs(company_file_path, session, username).present?
          QBWC.logger.info "Authentication of user '#{username}' succeeded, but no jobs pending for '#{company_file_path}'."
          company_file_path = AUTHENTICATE_NO_WORK
        else
          QBWC.logger.info "Authentication of user '#{username}' succeeded, jobs are pending for '#{company_file_path}'."
          QBWC.session_initializer.call(session) unless QBWC.session_initializer.nil?
        end
      end
      render :soap => {"tns:authenticateResult" => {"tns:string" => [ticket || '', company_file_path]}}
    end

    def send_request
      #req = QBWC::Request.new({:customer_query_rq => {
                #:xml_attributes => { "requestID" =>"1", 'iterator'  => "Start" },
                #:max_returned => 100,
                #:owner_id => "{57F3B9B1-86F1-4fcc-B1EE-566DE1813D20}"
                #}
                #})
      #req = req.request
      request = @session.request_to_send

      #puts "============>>> #{req} =========>>>>"
      render :soap => {'tns:sendRequestXMLResult' => request}
    end

    def receive_response
      if params[:hresult]
        QBWC.logger.warn "#{params[:hresult]}: #{params[:message]}"
        @session.error = params[:message]
        @session.status_code = params[:hresult]
        @session.status_severity = 'Error'
      end
      @session.response = params[:response]
      puts "response========>#{params[:response]}"
      render :soap => {'tns:receiveResponseXMLResult' => (QBWC::on_error == 'continueOnError' || @session.error.nil?) ? @session.progress : -1}
    end

    def close_connection
      @session.destroy
      render :soap => {'tns:closeConnectionResult' => 'OK'}
    end

    def connection_error
      @session.destroy
      logger.warn "#{params[:hresult]}: #{params[:message]}"
      render :soap => {'tns:connectionErrorResult' => 'done'}
    end

    def get_last_error
      render :soap => {'tns:getLastErrorResult' => @session.error || ''}
    end

    def app_name
      "#{Rails.application.class.parent_name} #{Rails.env} #{@app_name_suffix}"
    end

    def file_id
      '90A44FB5-33D9-4815-AC85-BC87A7E7D1EB'
    end

    protected

    def get_session(ticket = params[:ticket])
      @session = QBWC.storage_module::Session.get(ticket)
    end

    def save_session
      @session.save if @session
    end

    def server_version_response
    end

    def check_client_version
    end
    
    def import_customers(username, client_id)
      data = {username: username, action: "import_customers", client_id: client_id}
      request = {
        :customer_query_rq => {
          :xml_attributes => { "requestID" =>"1", 'iterator'  => "Start" },
          :max_returned => 3000
        }
      }
      QBWC.add_job("import_customers_#{client_id}", true, '', CustomerWorker, request, data)
    end
  
    def import_vendors(username, client_id)
      data = {username: username, action: "import_vendors", client_id: client_id}
      request = {
        :vendor_query_rq => {
          :xml_attributes => { "requestID" =>"1", 'iterator'  => "Start" },
          :max_returned => 3000
        }
      }
      QBWC.add_job("import_vendors_#{client_id}", true, '', VendorWorker, request, data)
    end
  end
end