import 'package:shared_preferences/shared_preferences.dart';

/// The only thing this app keeps on the phone besides the keystore key: which wallet is yours.
///
/// Deliberately not the card data, not the balance, not any signature: the chain holds all of that.
class WalletStore {
  static const _key = 'wallet_address';

  static Future<String?> address() async =>
      (await SharedPreferences.getInstance()).getString(_key);

  static Future<void> setAddress(String address) async =>
      (await SharedPreferences.getInstance()).setString(_key, address);

  static Future<void> clear() async =>
      (await SharedPreferences.getInstance()).remove(_key);
}
