# File names whose constants Zeitwerk can't infer.
Rails.autoloaders.each do |autoloader|
  autoloader.inflector.inflect("oauth_state" => "OAuthState")
end
