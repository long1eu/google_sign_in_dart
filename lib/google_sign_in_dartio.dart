library google_sign_in_dartio;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart'
    as platform;
import 'package:http/http.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

part 'src/code_exchange_sign_in.dart';
part 'src/common.dart';
part 'src/crypto.dart';
part 'src/data_storage.dart';
part 'src/token_sign_in.dart';

/// Signature used by the [_codeExchangeSignIn] to allow opening a browser window
/// in a platform specific way.
typedef UrlPresenter = void Function(Uri uri);

/// Implementation of the google_sign_in plugin in pure dart.
class GoogleSignInDart extends platform.GoogleSignInPlatform {
  GoogleSignInDart._({
    required DataStorage storage,
    required String clientId,
    required UrlPresenter presenter,
    String? exchangeEndpoint,
    String? appRedirectUrl,
    int? port,
  })  : _storage = storage,
        _clientId = clientId,
        _appRedirectUrl = appRedirectUrl,
        presenter = presenter,
        _port = port,
        _exchangeEndpoint = exchangeEndpoint;

  /// Registers this implementation as default implementation for GoogleSignIn
  ///
  /// Your application should provide a [storage] implementation that can store
  /// the tokens is a secure, long-lived location that is accessible between
  /// different invocations of your application.
  static Future<void> register({
    required String clientId,
    String? exchangeEndpoint,
    Store? store,
    UrlPresenter? presenter,
    int? port,
    String? appRedirectUrl,
  }) async {
    presenter ??= (Uri uri) => launchUrl(uri);

    if (store == null) {
      WidgetsFlutterBinding.ensureInitialized();
      final SharedPreferences _preferences =
          await SharedPreferences.getInstance();
      store = _SharedPreferencesStore(_preferences);
    }

    final DataStorage storage = DataStorage._(store: store, clientId: clientId);

    // If tokenExchangeEndpoint is removed in a session after the user was
    // logged in, we need to clear the refresh token since we can non longer use
    // it.
    if (storage.refreshToken != null && exchangeEndpoint == null) {
      storage.refreshToken = null;
    }

    platform.GoogleSignInPlatform.instance = GoogleSignInDart._(
      presenter: presenter,
      storage: storage,
      exchangeEndpoint: exchangeEndpoint,
      clientId: clientId,
      port: port,
      appRedirectUrl: appRedirectUrl,
    );
  }

  final String? _exchangeEndpoint;
  final String _clientId;
  final String? _appRedirectUrl;
  final DataStorage _storage;
  final int? _port;

  late List<String> _scopes;
  String? _hostedDomain;

  platform.GoogleSignInTokenData? _tokenData;
  String? _refreshToken;
  DateTime? _expiresAt;

  /// Used by the sign in flow to allow opening of a browser in a platform
  /// specific way.
  ///
  /// You can open the link in a in-app WebView or you can open it in the system
  /// browser
  UrlPresenter presenter;

  @override
  Future<void> init({
    String? hostedDomain,
    List<String> scopes = const <String>[],
    platform.SignInOption signInOption = platform.SignInOption.standard,
    String? clientId,
  }) async {
    assert(clientId == null || clientId == _clientId,
        'ClientID ($clientId) does not match the one used to register the plugin $_clientId.');
    assert(
        !scopes.any((String scope) => scope.contains(' ')),
        'OAuth 2.0 Scopes for Google APIs can\'t contain spaces.'
        'Check https://developers.google.com/identity/protocols/googlescopes '
        'for a list of valid OAuth 2.0 scopes.');

    if (scopes.isEmpty) {
      _scopes = const <String>['openid', 'email', 'profile'];
    } else {
      _scopes = scopes;
    }
    _hostedDomain = hostedDomain;
    _initFromStore();
  }

  @override
  Future<platform.GoogleSignInUserData?> signInSilently() async {
    if (_haveValidToken) {
      return _storage.userData;
    } else if (_refreshToken != null) {
      try {
        await _doTokenRefresh();
        return _storage.userData;
      } catch (e) {
        throw PlatformException(
            code: GoogleSignIn.kSignInFailedError, message: e.toString());
      }
    }

    throw PlatformException(code: GoogleSignIn.kSignInRequiredError);
  }

  @override
  Future<platform.GoogleSignInUserData?> signIn() async {
    if (_haveValidToken) {
      final platform.GoogleSignInUserData? userData = _storage.userData;
      if (userData == null) {
        await _fetchUserProfile();
      }
      return _storage.userData;
    } else {
      await _performSignIn(_scopes);
      return _storage.userData;
    }
  }

  @override
  Future<platform.GoogleSignInTokenData> getTokens(
      {required String email, bool? shouldRecoverAuth = true}) async {
    if (_haveValidToken) {
      return _tokenData!;
    } else if (_refreshToken != null) {
      // if refreshing the token fails, and shouldRecoverAuth is true, then we
      // will prompt the user to login again
      try {
        await _doTokenRefresh();
        return _tokenData!;
      } catch (_) {}
    }

    if (shouldRecoverAuth ?? true) {
      await _performSignIn(_scopes);
      return _tokenData!;
    } else {
      throw PlatformException(
          code: GoogleSignInAccount.kUserRecoverableAuthError);
    }
  }

  @override
  Future<void> signOut() async {
    _storage.clearAll();
    _initFromStore();
  }

  @override
  Future<void> disconnect() async {
    await _revokeToken();
    _storage.clear();
    _initFromStore();
  }

  @override
  Future<bool> isSignedIn() async {
    if (_haveValidToken) {
      return true;
    } else if (_refreshToken != null) {
      try {
        await _doTokenRefresh();
        return _haveValidToken;
      } catch (_) {}
    }

    return false;
  }

  @override
  Future<void> clearAuthCache({String? token}) async {
    await _revokeToken();
    _storage.clear();
    _initFromStore();
  }

  @override
  Future<bool> requestScopes(List<String> scopes) async {
    List<String> grantedScopes = _storage.scopes;
    final List<String> missingScopes =
        scopes.where((String scope) => !grantedScopes.contains(scope)).toList();

    if (missingScopes.isEmpty) {
      return true;
    }

    await _performSignIn(missingScopes);

    grantedScopes = _storage.scopes;
    return scopes.every((String scope) => grantedScopes.contains(scope));
  }

  Future<void> _revokeToken() async {
    if (_haveValidToken) {
      final String? token = _tokenData!.accessToken;

      await get(
        Uri.parse('https://oauth2.googleapis.com/revoke?token=$token'),
        headers: <String, String>{
          'content-type': 'application/x-www-form-urlencoded'
        },
      );
    }
  }

  Future<void> _fetchUserProfile() async {
    if (_haveValidToken) {
      final String token = _tokenData!.accessToken!;
      final Response response = await get(
        Uri.parse('https://openidconnect.googleapis.com/v1/userinfo'),
        headers: <String, String>{
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode > 300) {
        if (response.statusCode == 401) {
          await signOut();
        }
        throw PlatformException(
          code: GoogleSignInAccount.kFailedToRecoverAuthError,
          message: response.body,
        );
      }

      final Map<String, dynamic> result = jsonDecode(response.body);
      _storage.saveUserProfile(result);
    }
  }

  bool get _haveValidToken {
    return _expiresAt != null && DateTime.now().isBefore(_expiresAt!);
  }

  Future<void> _performSignIn(List<String> scopes) async {
    Future<Map<String, dynamic>> future;
    if (_exchangeEndpoint != null) {
      future = _codeExchangeSignIn(
        scope: scopes.join(' '),
        clientId: _clientId,
        hostedDomains: _hostedDomain,
        presenter: presenter,
        exchangeEndpoint: _exchangeEndpoint!,
        uid: _storage.id,
        appRedirectUrl: _appRedirectUrl,
      );
    } else {
      future = _tokenSignIn(
        scope: scopes.join(' '),
        clientId: _clientId,
        hostedDomains: _hostedDomain,
        presenter: presenter,
        uid: _storage.id,
        port: _port,
        appRedirectUrl: _appRedirectUrl,
      );
    }

    final Map<String, dynamic> result = await future.catchError(
      (dynamic error, StackTrace s) {
        throw PlatformException(
          code: GoogleSignInAccount.kFailedToRecoverAuthError,
          message: error.toString(),
        );
      },
    );

    print("result: ${jsonEncode(result)}");
    _storage.saveResult(result);
    _initFromStore();
    await _fetchUserProfile();
  }

  Future<void> _doTokenRefresh() async {
    assert(_exchangeEndpoint != null);
    assert(_refreshToken != null);

    final Response response = await post(
      Uri.parse(_exchangeEndpoint!),
      body: json.encode(<String, String>{
        'refreshToken': _refreshToken!,
        'clientId': _clientId,
      }),
    );
    if (response.statusCode == 200) {
      final Map<String, dynamic> result =
          Map<String, dynamic>.from(jsonDecode(response.body));

      _storage.saveResult(result);
      _initFromStore();
      await _fetchUserProfile();
    } else {
      throw response.body;
    }
  }

  void _initFromStore() {
    _refreshToken = _storage.refreshToken;
    _expiresAt = _storage.expiresAt;
    _tokenData = _storage.tokenData;
  }
}
