import '../../core/api_client.dart';

/// The shop profile shown/edited on the Store Settings screen — legal/trade
/// name, GSTIN, FSSAI license, contact, address, invoice prefix, plus
/// receipt header/footer text. See
/// services/api/internal/httpapi/settings_handlers.go.
class StoreProfile {
  final String legalName;
  final String? tradeName;
  final String? gstin;
  final String? fssaiLicenseNo;
  final String? phone;
  final String? email;
  final String addressLine1;
  final String? addressLine2;
  final String city;
  final String? district;
  final String stateCode;
  final String? postalCode;
  final String invoicePrefix;
  final String? receiptHeader;
  final String? receiptFooter;
  /// The shop's uploaded logo as a data: URI (e.g.
  /// "data:image/png;base64,..."), printed on the invoice PDF and detail
  /// screen header. Null means no logo has been uploaded yet.
  final String? logoDataUri;

  StoreProfile({
    required this.legalName,
    this.tradeName,
    this.gstin,
    this.fssaiLicenseNo,
    this.phone,
    this.email,
    required this.addressLine1,
    this.addressLine2,
    required this.city,
    this.district,
    required this.stateCode,
    this.postalCode,
    required this.invoicePrefix,
    this.receiptHeader,
    this.receiptFooter,
    this.logoDataUri,
  });

  factory StoreProfile.fromJson(Map<String, dynamic> json) {
    return StoreProfile(
      legalName: json['legal_name'] as String,
      tradeName: json['trade_name'] as String?,
      gstin: json['gstin'] as String?,
      fssaiLicenseNo: json['fssai_license_no'] as String?,
      phone: json['phone'] as String?,
      email: json['email'] as String?,
      addressLine1: json['address_line1'] as String,
      addressLine2: json['address_line2'] as String?,
      city: json['city'] as String,
      district: json['district'] as String?,
      stateCode: json['state_code'] as String,
      postalCode: json['postal_code'] as String?,
      invoicePrefix: json['invoice_prefix'] as String,
      receiptHeader: json['receipt_header'] as String?,
      receiptFooter: json['receipt_footer'] as String?,
      logoDataUri: json['logo_data_uri'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'legal_name': legalName,
        'trade_name': tradeName,
        'gstin': gstin,
        'fssai_license_no': fssaiLicenseNo,
        'phone': phone,
        'email': email,
        'address_line1': addressLine1,
        'address_line2': addressLine2,
        'city': city,
        'district': district,
        'state_code': stateCode,
        'postal_code': postalCode,
        'invoice_prefix': invoicePrefix,
        'receipt_header': receiptHeader,
        'receipt_footer': receiptFooter,
        'logo_data_uri': logoDataUri,
      };
}

class StoreSettingsApi {
  final ApiClient client;

  StoreSettingsApi(this.client);

  Future<StoreProfile> getStoreProfile() async {
    final response = await client.getAuthed('/api/v1/settings/store-profile');
    return StoreProfile.fromJson(response);
  }

  Future<StoreProfile> updateStoreProfile(StoreProfile profile) async {
    final response = await client.putAuthed('/api/v1/settings/store-profile', profile.toJson());
    return StoreProfile.fromJson(response);
  }
}
