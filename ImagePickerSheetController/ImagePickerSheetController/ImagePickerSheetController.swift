//
//  ImagePickerController.swift
//  ImagePickerSheet
//
//  Created by Laurin Brandner on 24/05/15.
//  Copyright (c) 2015 Laurin Brandner. All rights reserved.
//

import Foundation
import Photos
import UIKit

private let previewCollectionViewInset: CGFloat = 5

/// The media type an instance of ImagePickerSheetController can display
public enum ImagePickerMediaType {
    case image
    case video
    case imageAndVideo
}

@available(iOS 8.0, *)
open class ImagePickerSheetController: UIViewController {
    
    fileprivate lazy var sheetController: SheetController = {
        let controller = SheetController(previewCollectionView: self.previewCollectionView)
        controller.actionHandlingCallback = { [weak self] in
            self?.dismiss(animated: true, completion: nil)
        }
        
        return controller
    }()
    
    var sheetCollectionView: UICollectionView {
        return sheetController.sheetCollectionView
    }
    
    fileprivate(set) lazy var previewCollectionView: PreviewCollectionView = {
        let collectionView = PreviewCollectionView()
        collectionView.accessibilityIdentifier = "ImagePickerSheetPreview"
        collectionView.backgroundColor = .clear
        collectionView.allowsMultipleSelection = true
        collectionView.imagePreviewLayout.sectionInset = UIEdgeInsets(top: previewCollectionViewInset, left: previewCollectionViewInset, bottom: previewCollectionViewInset, right: previewCollectionViewInset)
        collectionView.imagePreviewLayout.showsSupplementaryViews = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.register(PreviewCollectionViewCell.self, forCellWithReuseIdentifier: NSStringFromClass(PreviewCollectionViewCell.self))
        collectionView.register(PreviewSupplementaryView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: NSStringFromClass(PreviewSupplementaryView.self))
        
        return collectionView
    }()
    
    fileprivate var supplementaryViews = [Int: PreviewSupplementaryView]()
    
    lazy var backgroundView: UIView = {
        let view = UIView()
        view.accessibilityIdentifier = "ImagePickerSheetBackground"
        view.backgroundColor = UIColor(white: 0.0, alpha: 0.3961)
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(ImagePickerSheetController.cancel)))
        
        return view
    }()
    
    /// All the actions. The first action is shown at the top.
    open var actions: [ImagePickerAction] {
        return sheetController.actions
    }
    
    /// Maximum selection of images.
    open var maximumSelection: Int?
    
    fileprivate var selectedImageIndices = [Int]() {
        didSet {
            var images = false
            var videos = false
            for (_, section) in selectedImageIndices.enumerated() {
                let asset = assets[section]
                switch asset.mediaType {
                case .image:
                    images = true
                    
                case .video:
                    videos = true
                    
                default: break
                }
            }
            var mediaType = ImagePickerMediaType.image
            if (videos && !images) {
                mediaType = .video
            } else if (videos && images) {
                mediaType = .imageAndVideo
            }
            sheetController.contentType = mediaType
            sheetController.numberOfSelectedImages = selectedImageIndices.count
        }
    }
    
    /// The selected image assets
    open var selectedImageAssets: [PHAsset] {
        return selectedImageIndices.map { self.assets[$0] }
    }
    
    /// The media type of the displayed assets
    public let mediaType: ImagePickerMediaType
    
    fileprivate var assets = [PHAsset]()
    
    fileprivate lazy var requestOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        
        return options
    }()
    
    fileprivate let imageManager = PHCachingImageManager()
    
    /// Whether the image preview has been elarged. This is the case when at least once
    /// image has been selected.
    open fileprivate(set) var enlargedPreviews = false
    
    fileprivate let minimumPreviewHeight: CGFloat = 129
    fileprivate var maximumPreviewHeight: CGFloat = 129
    
    fileprivate var previewCheckmarkInset: CGFloat {
        guard #available(iOS 9, *) else {
            return 3.5
        }
        
        return 12.5
    }
    
    // MARK: - Initialization
    
    public init(mediaType: ImagePickerMediaType) {
        self.mediaType = mediaType
        super.init(nibName: nil, bundle: nil)
        initialize()
    }

    public required init?(coder aDecoder: NSCoder) {
        self.mediaType = .imageAndVideo
        super.init(coder: aDecoder)
        initialize()
    }
    
    fileprivate func initialize() {
        modalPresentationStyle = .custom
        transitioningDelegate = self
        
        NotificationCenter.default.addObserver(self, selector: #selector(ImagePickerSheetController.cancel), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - View Lifecycle
    
    override open func loadView() {
        super.loadView()
        
        view.addSubview(backgroundView)
        view.addSubview(sheetCollectionView)
    }
    
    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        preferredContentSize = CGSize(width: 400, height: view.frame.height)
        
        if PHPhotoLibrary.authorizationStatus() == .authorized {
            prepareAssets()
        }
    }
    
    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if PHPhotoLibrary.authorizationStatus() == .notDetermined {
            PHPhotoLibrary.requestAuthorization() { status in
                if status == .authorized {
                    DispatchQueue.main.async {
                        self.prepareAssets()
                        self.previewCollectionView.reloadData()
                        self.sheetCollectionView.reloadData()
                        self.view.setNeedsLayout()
                        
                        // Explicitely disable animations so it wouldn't animate either
                        // if it was in a popover
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        self.view.layoutIfNeeded()
                        CATransaction.commit()
                    }
                }
            }
        }
    }
    
    // MARK: - Actions
    
    /// Adds an new action.
    /// If the passed action is of type Cancel, any pre-existing Cancel actions will be removed.
    /// Always arranges the actions so that the Cancel action appears at the bottom.
    open func addAction(_ action: ImagePickerAction) {
        sheetController.addAction(action)
        view.setNeedsLayout()
    }
    
    @objc fileprivate func cancel() {
        sheetController.handleCancelAction()
    }
    
    // MARK: - Images
    
    fileprivate func sizeForAsset(_ asset: PHAsset, scale: CGFloat = 1) -> CGSize {
        let proportion = CGFloat(asset.pixelWidth)/CGFloat(asset.pixelHeight)
    
        let imageHeight = maximumPreviewHeight - 2 * previewCollectionViewInset
        let imageWidth = floor(proportion * imageHeight)
        
        return CGSize(width: imageWidth * scale, height: imageHeight * scale)
    }
    
    fileprivate func prepareAssets() {
        fetchAssets()
        reloadMaximumPreviewHeight()
        reloadCurrentPreviewHeight(invalidateLayout: false)
        
        // Filter out the assets that are too thin. This can't be done before becuase
        // we don't know how tall the images should be
        let minImageWidth = 2 * previewCheckmarkInset + (PreviewSupplementaryView.checkmarkImage?.size.width ?? 0)
        assets = assets.filter { asset in
            let size = sizeForAsset(asset)
            return size.width >= minImageWidth
        }
    }
    
    fileprivate func fetchAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        switch mediaType {
        case .image:
            options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        case .video:
            options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.video.rawValue)
        case .imageAndVideo:
            options.predicate = NSPredicate(format: "mediaType = %d OR mediaType = %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        }
        
        let fetchLimit = 50
        if #available(iOS 9, *) {
            options.fetchLimit = fetchLimit
        }
        
        let result = PHAsset.fetchAssets(with: options)
        let requestOptions = PHImageRequestOptions()
        requestOptions.isSynchronous = true
        requestOptions.deliveryMode = .fastFormat
        
        result.enumerateObjects ({ (asset, _, stop) in
            defer {
                if self.assets.count > fetchLimit {
                    stop.initialize(to: true)
                }
            }
            self.imageManager.requestImageData(for: asset, options: requestOptions) { data, _, _, info in
                if data != nil {
                    self.assets.append(asset)
                }
            }
        })
    }
    
    fileprivate func requestImageForAsset(_ asset: PHAsset, completion: @escaping (_ image: UIImage?) -> ()) {
        let targetSize = sizeForAsset(asset, scale: UIScreen.main.scale)
        requestOptions.isSynchronous = true
        
        // Workaround because PHImageManager.requestImageForAsset doesn't work for burst images
        if asset.representsBurst {
            imageManager.requestImageData(for: asset, options: requestOptions) { data, _, _, _ in
                let image = data.flatMap { UIImage(data: $0) }
                completion(image)
            }
        }
        else {
            imageManager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: requestOptions) { image, _ in
                completion(image)
            }
        }
    }
    
    fileprivate func prefetchImagesForAsset(_ asset: PHAsset) {
        let targetSize = sizeForAsset(asset, scale: UIScreen.main.scale)
        imageManager.startCachingImages(for: [asset], targetSize: targetSize, contentMode: .aspectFill, options: requestOptions)
    }
    
    // MARK: - Layout
    
    open override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        backgroundView.frame = view.bounds
        
        reloadMaximumPreviewHeight()
        reloadCurrentPreviewHeight(invalidateLayout: true)
        
        let sheetHeight = sheetController.preferredSheetHeight
        let sheetSize = CGSize(width: view.bounds.width, height: sheetHeight)
        
        // This particular order is necessary so that the sheet is layed out
        // correctly with and without an enclosing popover
        preferredContentSize = sheetSize
        sheetCollectionView.frame = CGRect(origin: CGPoint(x: view.bounds.minX, y: view.bounds.maxY-sheetHeight), size: sheetSize)
    }
    
    fileprivate func reloadCurrentPreviewHeight(invalidateLayout invalidate: Bool) {
        if assets.count <= 0 {
            sheetController.setPreviewHeight(0, invalidateLayout: invalidate)
        }
        else if assets.count > 0 && enlargedPreviews {
            sheetController.setPreviewHeight(maximumPreviewHeight, invalidateLayout: invalidate)
        }
        else {
            sheetController.setPreviewHeight(minimumPreviewHeight, invalidateLayout: invalidate)
        }
    }
    
    fileprivate func reloadMaximumPreviewHeight() {
        let maxHeight: CGFloat = 400
        let maxImageWidth = sheetController.preferredSheetWidth - 2 * previewCollectionViewInset

        let assetRatios = assets.map { CGSize(width: max($0.pixelHeight, $0.pixelWidth), height: min($0.pixelHeight, $0.pixelWidth)) }
                                .map { $0.height / $0.width }
            
        let assetHeights = assetRatios.map { $0 * maxImageWidth }
                                      .filter { $0 < maxImageWidth && $0 < maxHeight } // Make sure the preview isn't too high eg for squares
                                      .sorted(by: >)
        let assetHeight = ceil(assetHeights.first ?? 0)
        
        // Just a sanity check, to make sure this doesn't exceed 400 points
        let scaledHeight = max(min(assetHeight, maxHeight), 200)
        maximumPreviewHeight = scaledHeight + 2 * previewCollectionViewInset
    }
    
    // MARK: -
    
    func enlargePreviewsByCenteringToIndexPath(_ indexPath: IndexPath?, completion: ((Bool) -> ())?) {
        enlargedPreviews = true
        previewCollectionView.imagePreviewLayout.invalidationCenteredIndexPath = indexPath
        reloadCurrentPreviewHeight(invalidateLayout: false)
        
        view.setNeedsLayout()
        
        let animationDuration: TimeInterval
        if #available(iOS 9, *) {
            animationDuration = 0.2
        }
        else {
            animationDuration = 0.3
        }
        
        UIView.animate(withDuration: animationDuration, animations: {
            self.sheetCollectionView.reloadSections(IndexSet(integer: 0))
            self.view.layoutIfNeeded()
        }, completion: completion)
    }
    
}

// MARK: - UICollectionViewDataSource

extension ImagePickerSheetController: UICollectionViewDataSource {
    
    public func numberOfSections(in collectionView: UICollectionView) -> Int {
        return assets.count
    }
    
    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return 1
    }
    
    public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: NSStringFromClass(PreviewCollectionViewCell.self), for: indexPath) as! PreviewCollectionViewCell
        
        let asset = assets[(indexPath as NSIndexPath).section]
        cell.videoIndicatorView.isHidden = asset.mediaType != .video

        requestImageForAsset(asset) { image in
            cell.imageView.image = image
        }
        
        cell.isSelected = selectedImageIndices.contains((indexPath as NSIndexPath).section)
        
        return cell
    }
    
    public func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath:
        IndexPath) -> UICollectionReusableView {
        let view = collectionView.dequeueReusableSupplementaryView(ofKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: NSStringFromClass(PreviewSupplementaryView.self), for: indexPath) as! PreviewSupplementaryView
        view.isUserInteractionEnabled = false
        view.buttonInset = UIEdgeInsets(top: 0.0, left: previewCheckmarkInset, bottom: previewCheckmarkInset, right: 0.0)
        view.selected = selectedImageIndices.contains((indexPath as NSIndexPath).section)
        
        supplementaryViews[(indexPath as NSIndexPath).section] = view
        
        return view
    }
    
}

// MARK: - UICollectionViewDelegate

extension ImagePickerSheetController: UICollectionViewDelegate {
    
    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if let maximumSelection = maximumSelection {
            if selectedImageIndices.count >= maximumSelection,
                let previousItemIndex = selectedImageIndices.first {
                    supplementaryViews[previousItemIndex]?.selected = false
                    selectedImageIndices.remove(at: 0)
            }
        }
        
        // Just to make sure the image is only selected once
        selectedImageIndices = selectedImageIndices.filter { $0 != (indexPath as NSIndexPath).section }
        selectedImageIndices.append((indexPath as NSIndexPath).section)
        
        if !enlargedPreviews {
            enlargePreviewsByCenteringToIndexPath(indexPath) { _ in
                self.sheetController.reloadActionItems()
                self.previewCollectionView.imagePreviewLayout.showsSupplementaryViews = true
            }
        }
        else {
            // scrollToItemAtIndexPath doesn't work reliably
            if let cell = collectionView.cellForItem(at: indexPath) {
                var contentOffset = CGPoint(x: cell.frame.midX - collectionView.frame.width / 2.0, y: 0.0)
                contentOffset.x = max(contentOffset.x, -collectionView.contentInset.left)
                contentOffset.x = min(contentOffset.x, collectionView.contentSize.width - collectionView.frame.width + collectionView.contentInset.right)
                
                collectionView.setContentOffset(contentOffset, animated: true)
            }
            
            sheetController.reloadActionItems()
        }
        
        supplementaryViews[(indexPath as NSIndexPath).section]?.selected = true
    }
    
    public func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        if let index = selectedImageIndices.index(of: (indexPath as NSIndexPath).section) {
            selectedImageIndices.remove(at: index)
            sheetController.reloadActionItems()
        }
        
        supplementaryViews[(indexPath as NSIndexPath).section]?.selected = false
    }
    
}

// MARK: - UICollectionViewDelegateFlowLayout

extension ImagePickerSheetController: UICollectionViewDelegateFlowLayout {
    
    public func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let asset = assets[(indexPath as NSIndexPath).section]
        let size = sizeForAsset(asset)
        
        // Scale down to the current preview height, sizeForAsset returns the original size
        let currentImagePreviewHeight = sheetController.previewHeight - 2 * previewCollectionViewInset
        let scale = currentImagePreviewHeight / size.height
        
        return CGSize(width: size.width * scale, height: currentImagePreviewHeight)
    }

    public func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        let checkmarkWidth = PreviewSupplementaryView.checkmarkImage?.size.width ?? 0
        return CGSize(width: checkmarkWidth + 2 * previewCheckmarkInset, height: sheetController.previewHeight - 2 * previewCollectionViewInset)
    }
    
}

// MARK: - UIViewControllerTransitioningDelegate

extension ImagePickerSheetController: UIViewControllerTransitioningDelegate {
    
    public func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return AnimationController(imagePickerSheetController: self, presenting: true)
    }
    
    public func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return AnimationController(imagePickerSheetController: self, presenting: false)
    }
    
}
