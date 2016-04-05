//
//  CoreDataStack.swift
//  CoreDataStack
//
//  Created by Matthew Yannascoli on 4/1/16.
//  Copyright © 2016 my. All rights reserved.
//


import UIKit
import CoreData



/// CoreDataStack is a basic coredata setup that enables the creation of contained (sandboxed) instances
/// of a store and provides commonly used conveniences like deleting the store and creating an inMemory instance
/// for testing.
///
/// The underlying coredata configuration is typical where the `mainContext` inherits from
/// a concurrent private writing context that references the persistent store coordinator and
/// does the actual writing to disk.
///
/// [Private Writing Context (PWC)] -> concurrent, writes to disk
///             ^
///             |
///             |
///       [Main Context (MC)] -> synchronous, Child of PWC
///             ^
///             |
///             |
///     [Temporary Context] -> concurrent, spawn at will
///

public struct CoreDataStack {
    private var log = Log()
    
    //MARK: private
    private let bundle: NSBundle
    private let modelName: String
    private let containerURL: NSURL
    private let inMemoryStore: Bool

    private var persistentStoreCoordinator: NSPersistentStoreCoordinator?
    private var managedObjectModel: NSManagedObjectModel?
    private var writingContext: NSManagedObjectContext?
    
    
    //MARK: public
    ///Set to true to log debugging info to console.  Errors are always logged.
    public typealias ErrorCompletionBlock = ((error: NSError?) -> Void)?
    public var logDebugOutput: Bool {
        didSet {
            log.logDebugOutput = logDebugOutput
        }
    }
    private(set) internal var mainContext: NSManagedObjectContext?
}


//MARK: - LifeCycle -
///<>< Lifecycle ><>
extension CoreDataStack {
    //MARK: Public
    
    /// Create a stack instance.
    /// - `bundle` (required): NSBundle in which your target NSManagedObjectModel can be found.
    /// - `modelName` (required): must correspond with the name of the backing NSManagedObjectModel
    /// - `containerURL` (required): is a URL that points to the folder in which the backing sqlite files will be stored.
    /// - `inMemoryStore` :defaults to false. if true, will create the persistant store using the `NSInMemoryStoreType`
    /// - `logDebugOutput`:defaults to false. if true, will log helpful debugging output.
    ///
    /// The underlying persistant store is set hardcoded to use an sqlite database and as basic migration options
    /// (`NSMigratePersistentStoresAutomaticallyOption` and `NSInferMappingModelAutomaticallyOption`) set to true.
    public init(bundle: NSBundle, modelName: String, containerURL: NSURL, inMemoryStore: Bool = false, logDebugOutput: Bool = false) {
        self.bundle = bundle
        self.modelName = modelName
        self.containerURL = containerURL
        self.inMemoryStore = inMemoryStore
        self.logDebugOutput = logDebugOutput

        setup()
    }
    
    ///Tears down the stack by removing and niling the current persistentStoreCoordinator, niling the
    ///managedObjectModel and resets the writing and main contexts in a thread-safe manner. Subsequently,
    ///all the files with an sqlite* extension (the sqlite, sqlite-wal and sqlite-shm) are deleted from disk.
    ///This deletion is done asyncronously on the `writingContext`.
    ///
    ///¡BE CAREFUL! as your DB data will not be recoverable after this method is called.
    ///
    ///By default the `rejuvenate` option is set to true which will cause the stack to be setup again from scratch.
    ///If you do not wish the stack to be rejuvenated in this manner pass false.  Effectively, this will render
    ///the stack instance useless but is valuable if you are planning on discontinuing the stack altogether
    ///and do not wish to incur the extra overhead of setting it up again.
    ///
    ///The optional completion block param is called the main queue.
    public mutating func deleteStore(andRejuvenate rejuvenate: Bool = true, completion: ErrorCompletionBlock = nil) {
        //1.
        tearDown()
        
        //2.
        removeDBFiles(completion)
        
        if rejuvenate {
            setup()
        }
    }
    
    ///Returns false if the stack was not setup, true if the stack was setup successfully.
    private mutating func setup() -> Bool {
        setupStore()
        
        guard let _ = persistentStoreCoordinator,
                  _ = writingContext,
                  _ = mainContext,
                  _ = managedObjectModel else {
            
            tearDown()
            return false
        }
        
        return true
    }
    
    private mutating func tearDown() {
        if removePersistentStore() {
            managedObjectModel = nil
            persistentStoreCoordinator = nil
            
            writingContext?.performBlockAndWait{
                self.writingContext?.reset()
            }
            
            mainContext?.performBlockAndWait{
                self.mainContext?.reset()
            }
        }
        else {
            log.debug("Stack not torn down because persistent store was not removed.")
        }
    }
    
    //MARK: Private
    private mutating func setupStore() {
        //1.
        managedObjectModel = createManagedObjectModel()
        
        //2.
        persistentStoreCoordinator = createPersistentStoreCoordinator()
        
        //3.
        writingContext = createWritingContext()
        
        //4.
        mainContext = createMainContext()
    }
    
    private func removePersistentStore() -> Bool {
        let lastStore = persistentStoreCoordinator?.persistentStores.last
        guard let store = lastStore else {
            log.error("Not removing `persistentStoreCoordinator` because none exists to remove.")
            return false
        }
        
        do {
            try self.persistentStoreCoordinator?.removePersistentStore(store)
            return true
        }
        catch let error as NSError {
            log.error("Unable to remove the persistent store with error: \(error.localizedDescription)")
            return false
        }
    }

    private func removeDBFiles(completion: ErrorCompletionBlock = nil) {
        func completeOnMain(error: NSError? = nil) {
            dispatch_async(dispatch_get_main_queue()) {
                completion?(error: error)
            }
        }
        
        //Remove files on the writingContext to make sure nothing is writing when the files are removed.
        writingContext?.performBlockAndWait {
            let fileManager = NSFileManager.defaultManager()
            
            do {
                let urls = try fileManager.contentsOfDirectoryAtURL(
                    self.containerURL, includingPropertiesForKeys: [], options: .SkipsSubdirectoryDescendants)
                
                let sqliteUrls = urls.filter { nil != $0.absoluteString.rangeOfString("\(self.modelName).sqlite") }
                for url in sqliteUrls {
                    do {
                        try fileManager.removeItemAtURL(url)
                    }
                    catch let error as NSError {
                        self.log.error("Unable to remove sqlite file with error: \(error.localizedDescription)")
                        completeOnMain(error)
                        
                        //Bail if we get at least one error.
                        break
                    }
                }
                
                completeOnMain()
            }
            catch let error as NSError {
                self.log.error("Unable to fetch contents of container (dataDirectory) with error: \(error.localizedDescription)")
                completeOnMain(error)
            }
        }
    }
}


//MARK: - Context API -
///<><  Contexts ><>
extension CoreDataStack {
    
    ///Save down through the context chain to disk.  If no context is specified `mainContext` is assumed.
    public func saveToDisk(context: NSManagedObjectContext? = nil, completion: ErrorCompletionBlock = nil) {
        func complete(error: NSError? = nil) {
            dispatch_async(dispatch_get_main_queue(), {
                completion?(error: error)
            })
        }
        
        func save(context: NSManagedObjectContext?, saveCompletion: (() -> Void)? = nil) {
            context?.performBlock {
                do {
                    try context?.save()
                    saveCompletion?()
                }
                catch let error as NSError {
                    self.log.error("Context save failed with error: \(error.localizedDescription)")
                    complete(error)
                }
            }
        }
        
        //
        if let context = context where context != mainContext {
            save(context) {
                save(self.mainContext) {
                    save(self.writingContext) {
                        complete()
                    }
                }
            }
        }
        else {
            save(self.mainContext) {
                //save(self.writingContext) {
                    complete()
                //}
            }
        }
    }
    
    ///Spawn a temporary concurrent context.  This context inherits from the mainContext and will propogate
    ///it's save through the `mainContext` and ultimately to the `writingContext` when passed to the
    ///`saveToDisk` function.
    public func concurrentContext() -> NSManagedObjectContext? {
        guard let mc = self.mainContext else {
            log.error("Unable to create concurrent context because the mainContext is not currently set up.")
            return nil
        }
        
        let managedObjectContext = NSManagedObjectContext(concurrencyType: .PrivateQueueConcurrencyType)
        managedObjectContext.parentContext = mc
        return managedObjectContext
    }
}



//MARK: - Stack -
extension CoreDataStack {
    
    private func createManagedObjectModel() -> NSManagedObjectModel? {
        guard managedObjectModel == nil else {
            return managedObjectModel!
        }
        
        let modelURL = bundle.URLForResource(modelName, withExtension: "momd")
        guard let mURL = modelURL else {
            fatalError("Unabled able to find object model file with name: \(modelName)")
        }
        
        guard let managedObjectModel = NSManagedObjectModel(contentsOfURL: mURL) else {
            fatalError("Unabled to instantiate `managedObjectModel` with name \"\(modelName)\".  Bailing.")
        }
        
        return managedObjectModel
    }
    
    
    private mutating func createPersistentStoreCoordinator() -> NSPersistentStoreCoordinator? {
        guard let mom = managedObjectModel else {
            fatalError("Attempting to create a `persistentStoreCoordinator` but one already exists.")
        }
        
        guard persistentStoreCoordinator == nil else {
            return persistentStoreCoordinator
        }
        
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: mom)
        let url = containerURL.URLByAppendingPathComponent("\(modelName).sqlite")
        let storeType = inMemoryStore ? NSInMemoryStoreType : NSSQLiteStoreType
        
        let options = [
            NSMigratePersistentStoresAutomaticallyOption : true,
            NSInferMappingModelAutomaticallyOption : true
        ]
        
        do {
            try coordinator.addPersistentStoreWithType(storeType, configuration: nil, URL: url, options: options)
        }
        catch let error as NSError {
            log.error("Attempt to add `persistentStoreCoordinator` failed with error: \(error.localizedDescription)")
            self.removeDBFiles()
        }
        
        return coordinator
    }
    
    
    private func createWritingContext() -> NSManagedObjectContext? {
        guard let psc = persistentStoreCoordinator else {
            log.debug("Attempting to create `writingContext` before the `persistentStoreCoordinator` is set up.")
            return nil
        }
        
        guard writingContext == nil else {
            return writingContext
        }

        let managedObjectContext = NSManagedObjectContext(concurrencyType: .PrivateQueueConcurrencyType)
        managedObjectContext.persistentStoreCoordinator = psc
        return managedObjectContext
    }
    
    
    private func createMainContext() -> NSManagedObjectContext? {
        guard let wc = writingContext else {
            log.error("Attempting to create `mainContext` before the persistent store coordinator is setup.")
            return nil
        }
        
        guard mainContext == nil else {
            return mainContext
        }

        let managedObjectContext = NSManagedObjectContext(concurrencyType: .MainQueueConcurrencyType)
        managedObjectContext.parentContext = wc
        return managedObjectContext
    }
}



//MARK: - Utilities -
private struct Log {
    var logDebugOutput: Bool = true
    
    func debug(message: String, file: String = #file, function: String = #function, line: Int = #line) {
        guard logDebugOutput else {
            return
        }
        
        print("+")
        print("File: \(file)")
        print("Function: \(function), Line: \(line)")
        debugPrint(message)
        print("+")
    }
    
    private func error(message: String, file: String = #file, function: String = #function, line: Int = #line) {
        print("+")
        print("File: \(file)")
        print("Function: \(function), Line: \(line)")
        debugPrint(message)
        print("+")
    }
}
