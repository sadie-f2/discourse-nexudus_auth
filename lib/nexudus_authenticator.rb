# frozen_string_literal: true
require 'omniauth'
require 'cgi'

module OmniAuth
  module Strategies
    class Nexudus
      include OmniAuth::Strategy
      option :name, 'nexudus'

      def request_phase
        [200, { 'Content-Type' => 'text/html; charset=utf-8' }, [login_html]]
      end

      def callback_phase
        email    = request.params['email'].to_s.strip.downcase
        password = request.params['password'].to_s

        if SiteSetting.nexudus_auth_diagnostics
          diag   = ::NexudusMembershipProvider.diagnose(email, password)
          member = diag.delete(:member)
          unless member
            return [200, { 'Content-Type' => 'text/html; charset=utf-8' },
                    [diag_html(email, diag)]]
          end
        else
          member = ::NexudusMembershipProvider.find_member(email)
          unless member && ::NexudusMembershipProvider.verify_password(email, password)
            return [200, { 'Content-Type' => 'text/html; charset=utf-8' },
                    [failure_html("Login failed. Check your email and password.")]]
          end
        end

        env['omniauth.auth'] = OmniAuth::AuthHash.new(
          provider: name,
          uid:      member[:email],
          info: {
            email: member[:email],
            name:  member[:name]
          },
          extra: { nexudus_id: member[:nexudus_id] }
        )
        call_app!
      end

      private

      def login_html
        token = request.env['rack.session']['omniauth.authenticity_token'].to_s
        nonce = request.env['action_dispatch.content_security_policy_nonce'].to_s
        nonce_attr = nonce.empty? ? '' : " nonce=\"#{CGI.escapeHTML(nonce)}\""
        <<~HTML
          <!DOCTYPE html><html><head><title>Log in with Nexudus</title>
          <style>
            body{font-family:sans-serif;padding:2em;max-width:400px;margin:0 auto}
            label{display:block;margin-bottom:.25em;font-weight:bold}
            input[type=email],input[type=password],input[type=text]{
              width:100%;padding:.5em;margin-bottom:1em;box-sizing:border-box;
              border:1px solid #ccc;border-radius:4px;font-size:1em}
            .pw-wrap{position:relative}
            .pw-wrap input{padding-right:4.5em}
            .pw-toggle{position:absolute;right:.5em;top:50%;transform:translateY(-50%);
              background:none;border:none;cursor:pointer;color:#555;font-size:.85em;padding:.2em .4em}
            .pw-toggle:hover{color:#000}
            input[type=submit]{width:100%;padding:.75em;background:#0088cc;color:#fff;
              border:none;border-radius:4px;font-size:1em;cursor:pointer}
            input[type=submit]:hover{background:#006699}
          </style></head>
          <body>
          <h2>Log in with Nexudus</h2>
          <form method="post" action="#{CGI.escapeHTML(callback_path)}">
            <input type="hidden" name="authenticity_token" value="#{CGI.escapeHTML(token)}">
            <label for="email">Email</label>
            <input type="email" id="email" name="email" autocomplete="email" autofocus required>
            <label for="password">Password</label>
            <div class="pw-wrap">
              <input type="password" id="password" name="password" autocomplete="current-password" required>
              <button type="button" class="pw-toggle" id="pw-btn">Show</button>
            </div>
            <input type="submit" value="Log in">
          </form>
          <script#{nonce_attr}>
            (function(){
              var p=document.getElementById('password'),b=document.getElementById('pw-btn');
              if(p&&b){b.addEventListener('click',function(){
                p.type=p.type==='password'?'text':'password';
                b.textContent=p.type==='password'?'Show':'Hide';
              });}
            })();
          </script>
          </body></html>
        HTML
      end

      def failure_html(message)
        <<~HTML
          <!DOCTYPE html><html><head><title>Login failed</title>
          <style>body{font-family:sans-serif;padding:2em;max-width:600px}</style></head>
          <body>
          <h2>Login failed</h2>
          <p>#{message}</p>
          <p><a href="/auth/nexudus">&#8592; Try again</a></p>
          </body></html>
        HTML
      end

      def diag_html(email, diag)
        rows = diag.map do |k, v|
          "<tr><td style='padding:6px 12px;border:1px solid #ccc'>#{k}</td>" \
          "<td style='padding:6px 12px;border:1px solid #ccc'><code>#{CGI.escapeHTML(v.to_s)}</code></td></tr>"
        end.join
        <<~HTML
          <!DOCTYPE html><html><head><title>Nexudus Auth Diagnostics</title>
          <style>body{font-family:monospace;padding:2em;max-width:800px}
          table{border-collapse:collapse;width:100%}
          tr:nth-child(even){background:#f5f5f5}</style></head>
          <body>
          <h2>Nexudus Auth — diagnostic output</h2>
          <p><strong>Email:</strong> #{CGI.escapeHTML(email)}</p>
          <table>#{rows}</table>
          <p><a href="/auth/nexudus">&#8592; Try again</a></p>
          </body></html>
        HTML
      end
    end
  end
end

class NexudusAuthenticator < Auth::Authenticator
  def name
    'nexudus'
  end

  def enabled?
    SiteSetting.nexudus_auth_enabled
  end

  def can_connect_existing_user?
    true
  end

  def register_middleware(omniauth)
    omniauth.provider :nexudus
  end

  def after_authenticate(auth_token, existing_account: nil)
    result             = Auth::Result.new
    info               = auth_token.info
    result.email       = info[:email]
    result.email_valid = true

    account     = UserAssociatedAccount.find_by(provider_name: name,
                                                provider_uid:  auth_token.uid)
    result.user = account&.user
    result.user ||= User.find_by_email(info[:email])
    result.name = info[:name] if result.user.nil?

    add_to_nexudus_group(result.user) if result.user

    result
  end

  def after_create_account(user, auth)
    super
    add_to_nexudus_group(user)
  end

  def after_connect_existing_user(user, auth)
    super
    add_to_nexudus_group(user)
  end

  private

  def add_to_nexudus_group(user)
    group_name = SiteSetting.nexudus_auth_group.to_s.strip
    group = Group.find_by(name: group_name)
    unless group
      Rails.logger.warn("[NexudusAuth] Group '#{group_name}' not found — create it in Discourse admin or update the nexudus_auth_group site setting")
      return
    end
    group.add(user) unless GroupUser.exists?(group_id: group.id, user_id: user.id)
  end
end
