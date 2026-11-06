class Property {
  final int id;
  final String category;
  final String type; // 'sell', 'local', 'buy'
  final String city;
  final String quartier;
  final String area;
  final String description;
  final String price;
  final String createdAt;
  final List<String> images;
  final String path;
  final String? ownerName;
  final String? ownerPhone;
  final String? clientName;
  final String? clientPhone;
  final bool isFavorite;
  final String? audioPath;
  final List<String> videos;
  final String? sharedBy;

  Property({
    required this.id,
    required this.category,
    required this.type,
    required this.city,
    required this.quartier,
    required this.area,
    required this.description,
    required this.price,
    required this.createdAt,
    required this.images,
    required this.path,
    this.ownerName,
    this.ownerPhone,
    this.clientName,
    this.clientPhone,
    this.isFavorite = false,
    this.audioPath,
    this.videos = const [],
    this.sharedBy,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'category': category,
        'type': type,
        'city': city,
        'quartier': quartier,
        'area': area,
        'description': description,
        'price': price,
        'createdAt': createdAt,
        'images': images,
        'path': path,
        'ownerName': ownerName,
        'ownerPhone': ownerPhone,
        'clientName': clientName,
        'clientPhone': clientPhone,
        'isFavorite': isFavorite,
        'audioPath': audioPath,
        'videos': videos,
        'sharedBy': sharedBy,
      };

  factory Property.fromJson(Map<String, dynamic> json, String propertyPath) {
    // Image paths are rebuilt from the property folder so data survives
    // transfers between devices and app-directory changes.
    final images = (json['images'] as List? ?? [])
        .map((e) => '$propertyPath/images/${e.toString().split(RegExp(r'[\\/]')).last}')
        .toList();
    final videos = (json['videos'] as List? ?? [])
        .map((e) => '$propertyPath/videos/${e.toString().split(RegExp(r'[\\/]')).last}')
        .toList();
    final rawAudio = json['audioPath']?.toString();
    final audio = (rawAudio == null || rawAudio.isEmpty)
        ? null
        : '$propertyPath/audio/${rawAudio.split(RegExp(r'[\\/]')).last}';
    return Property(
      id: (json['id'] as num?)?.toInt() ?? 0,
      category: json['category']?.toString() ?? '',
      type: json['type']?.toString() ?? 'sell',
      city: json['city']?.toString() ?? '',
      quartier: json['quartier']?.toString() ?? '',
      area: json['area']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      price: json['price']?.toString() ?? '',
      createdAt: json['createdAt']?.toString() ?? '',
      images: images,
      path: propertyPath,
      ownerName: json['ownerName']?.toString(),
      ownerPhone: json['ownerPhone']?.toString(),
      clientName: json['clientName']?.toString(),
      clientPhone: json['clientPhone']?.toString(),
      isFavorite: json['isFavorite'] == true,
      audioPath: audio,
      videos: videos,
      sharedBy: json['sharedBy']?.toString(),
    );
  }
}
