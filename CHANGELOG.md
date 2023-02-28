# 0.2.2+1
* Add pubspec.lock to .gitignore
* Update dependencies

## 0.2.2
* changed discounted shared_preferences_macos to shared_preferences_foundation thanks to https://github.com/TimYusR

## 0.2.1
* Add the option to specify a port for the local server.

## 0.2.0
BREAKING CHANGE:
* added `prompt` argument `select_account`, that forces the users to select user account they want to use

## 0.1.0
* migrate to null-safety

## 0.0.8
* add linux example app
* sign out when the userinfo endpoint returns 401
* if the user info is null but we have a valid token we try to fetch the user again

## 0.0.7

* add requestScopes

Note: `GoogleSignInTokenData` exposes `serverAuthCode` field that should
contain the exchange code from the authorization request. This will
always be null when using this package because we already allow you to
provide a code exchange endpoint witch exposes the code and code
verifier in a trusted environment and encourages not to do the code
exchange on the client.

## 0.0.6

* changed the name from `GoogleSignInPlatform` to `GoogleSignInDart` to match other packages

## 0.0.5

* fix passing the scopes when present 

## 0.0.4+1

* fix logic bug 

## 0.0.4

* add default scopes `openid`, `email`, `profile` 

## 0.0.3

* remove `isDesktop` 

## 0.0.2+1

* update readme 

## 0.0.2

* update readme 
* rename from `google_sign_in_dart` to `google_sign_in_dartio` due to the fact that the name was not available in pub

## 0.0.1

* Initial release.
