//
//  CoreDataStack.swift
//  CoreDataStack
//
//  Created by Matthew Yannascoli on 4/1/16.
//  Copyright © 2016 my. All rights reserved.
//


import UIKit
import CoreData


/// ><><><><><><><
///
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
/// ><><><><><><><
public struct CoreDataStack {
    //MARK: Properties
    private let bundle: NSBundle
    private let modelName: String
    private let containerURL: NSURL
    private let inMemoryStore: Bool

    private var persistentStoreCoordinator: NSPersistentStoreCoordinator?
    private var managedObjectModel: NSManagedObjectModel?
    private var writingContext: NSManagedObjectContext?
    
    private var contextsInvalid: Bool {
        guard let _ = mainContext, _ = writingContext else {
            return false
        }
        
        return true
    }
    
    //Custom Errors
    public enum CoreDataStackError: ErrorType, CustomDebugStringConvertible {
        case InvalidContextState
        
        public var debugDescription: String {
            switch self {
            case .InvalidContextState:
                let message = "This stack currently has a nil `mainContext` and/or a nil `writingContext`.  This is" +
                              "can happen if the `deleteStore` method is called without the rejuvenate flag set to" +
                              "true.  The only way to fix is to set up a new stack from scratch."
                
                return message
            }
        }
    }
    
    
    ///Reused completion block pattern that is used for completions.
    public typealias ErrorCompletionBlock = (() throws -> Void)?
    
    ///The main context. a NSManagedObjectContext that is created with the MainQueueConcurrencyType concurrencyType.
    private(set) internal var mainContext: NSManagedObjectContext?
}


//MARK: - API -
/// ><><><><><><><
public extension CoreDataStack {
    
    /// Create a stack instance.
    /// - `bundle` (required): NSBundle in which your target NSManagedObjectModel can be found.
    /// - `modelName` (required): must correspond with the name of the backing NSManagedObjectModel
    /// - `containerURL` (required): is a URL that points to the folder in which the backing sqlite files will be stored.
    /// - `inMemoryStore` :defaults to false. if true, will create the persistant store using the `NSInMemoryStoreType`
    /// - `logDebugOutput`:defaults to false. if true, will log helpful errors/debugging output.
    ///
    /// The underlying persistant store is set hardcoded to use an sqlite database and as basic migration options
    /// (`NSMigratePersistentStoresAutomaticallyOption` and `NSInferMappingModelAutomaticallyOption`) set to true.
    public init(bundle: NSBundle, modelName: String, containerURL: NSURL, inMemoryStore: Bool = false, logOutput: Bool = false) {
        self.bundle = bundle
        self.modelName = modelName
        self.containerURL = containerURL
        self.inMemoryStore = inMemoryStore
        
        loggingOn = logOutput
        setup()
    }
    
    ///Tears down the stack by removing and niling the current persistentStoreCoordinator, niling the
    ///managedObjectModel and resets the writing and main contexts in a thread-safe manner. Subsequently,
    ///all the files with an sqlite* extension (the sqlite, sqlite-wal and sqlite-shm) are deleted from disk.
    ///This deletion is done asyncronously on the `writingContext` but is ultimately dispatched back to main.
    ///
    ///¡BE CAREFUL! as your DB data will not be recoverable after this method is called.
    ///
    ///By default the `rejuvenate` option is set to true which will cause the stack to be setup again from scratch.
    ///If you do not wish the stack to be rejuvenated in this manner pass false.  Effectively, this will render
    ///the stack instance useless but is valuable if you are planning on discontinuing the stack altogether
    ///and do not wish to incur the extra overhead of setting it up again.
    ///
    ///The optional completion block param is called on the main queue.
    
    private func onMain(completion: ErrorCompletionBlock? -> Void, _ block: ErrorCompletionBlock)  {
        dispatch_async(dispatch_get_main_queue()) {
            completion(block)
        }
    }
    
    public mutating func deleteStore(andRejuvenate rejuvenate: Bool = true, completion: (ErrorCompletionBlock? -> Void)?) {
        if self.contextsInvalid {
            completion?({ throw CoreDataStackError.InvalidContextState })
            return
        }
        
        /*
        func doDeletion() {
            do {
                try self.removeDBFiles()
                onMain(completion)
            }
            catch let error as NSError {
                onMain(completion, withError: error)
            }
        }
        
        do {
            try self.tearDown()            
            if let writingContext = writingContext {
                writingContext.performBlock {
                    doDeletion()
                }
            }
            else {
                doDeletion()
            }
        }
        catch let error as NSError {
            onMain(completion, withError: error)
        }
        */
    }
    
    
    ///Save down through the context chain to disk.
    /// - `context` : optional MOC.  If nothing is passed, mainContext is assumed.
    /// - `completion` : optional completion block. Called on the main queue.
    ///
    public func saveToDisk(context: NSManagedObjectContext? = nil, completion: (ErrorCompletionBlock? -> Void)?) {
        if self.contextsInvalid {
            completion?({ throw CoreDataStackError.InvalidContextState })
            return
        }
        
        
        /*
        guard let mc = mainContext, wc = writingContext else {
            onMain(completion, withError: CoreDataStackError.InvalidStackState)
            return
        }
        
        func save(context: NSManagedObjectContext?, saveCompletion: (() -> Void)? = nil) {
            context?.performBlock {
                do {
                    try context?.save()
                    saveCompletion?()
                }
                catch let error as NSError {
                    Log("Context (\(context)) save failed with error: \(error.localizedDescription)")
                    self.onMain(completion, withError: error)
                }
            }
        }
        
        if let context = context where context != mainContext {
            //Propogate save down through the main context
            save(context) {
                save(self.mainContext) {
                    self.onMain(completion)
                }
            }
        }
        else {
            save(self.mainContext) {
                self.onMain(completion)
            }
        }
        */
    }
    
    
    /// Creates a concurrent context that inherits from the mainContext
    /// and will propogate its save down through the `mainContext` and ultimately to the
    /// `writingContext` when passed to the `saveToDisk` function.
    public func concurrentContext() -> NSManagedObjectContext? {
        guard let mc = self.mainContext else {
            Log("Unable to create concurrent context because the mainContext is not currently set up.")
            return nil
        }
        
        let managedObjectContext = NSManagedObjectContext(concurrencyType: .PrivateQueueConcurrencyType)
        managedObjectContext.parentContext = mc
        return managedObjectContext
    }
    
}


//MARK: - LifeCycle -
private extension CoreDataStack {
    
    ///Returns false if the stack was not setup, true if the stack was setup successfully.
    private mutating func setup() {
        setupStore()
        
        guard let _ = persistentStoreCoordinator,
                  _ = writingContext,
                  _ = mainContext,
                  _ = managedObjectModel else {
            
            Log("Something didn't go right while setting up the stack.  Attempting tear down...")
            do {
                try self.tearDown()
            }
            catch{}
            return
        }
    }
    
    private mutating func tearDown() throws {
        do {
            try removePersistentStore()
            
            managedObjectModel = nil
            persistentStoreCoordinator = nil
            self.mainContext?.reset()
            self.mainContext = nil
            self.writingContext?.reset()
            self.writingContext = nil
        }
        catch let error as NSError {
            throw error
        }
    }
    
    
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
    
    
    private func removePersistentStore() throws {
        let lastStore = persistentStoreCoordinator?.persistentStores.last
        guard let store = lastStore else {
            Log("Not removing persistent store because there isn't one to remove.")
            return
        }
        
        do {
            try self.persistentStoreCoordinator?.removePersistentStore(store)
        }
        catch let error as NSError {
            Log("Unable to remove the persistent store with error: \(error.localizedDescription)")
            throw error
        }
    }

    
    private func removeDBFiles() throws {
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
                    Log("Unable to remove sqlite file with error: \(error.localizedDescription)")
                    throw error
                }
            }
        }
        catch let error as NSError {
            Log("Unable to fetch contents of container directory with error: \(error.localizedDescription)")
            throw error
        }
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
            Log("Unabled able to find object model file with name: \(modelName)")
            return nil
        }
        
        guard let managedObjectModel = NSManagedObjectModel(contentsOfURL: mURL) else {
            Log("Unabled to instantiate `managedObjectModel` with name \"\(modelName)\".  Bailing.")
            return nil
        }
        
        return managedObjectModel
    }
    
    
    private mutating func createPersistentStoreCoordinator() -> NSPersistentStoreCoordinator? {
        guard let mom = managedObjectModel else {
            Log("Attempting to create a `persistentStoreCoordinator` but one already exists.")
            return nil
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
            Log("Attempt to add `persistentStoreCoordinator` failed with error: \(error.localizedDescription)")
            do {
                try self.removeDBFiles()
            }
            catch {}
        }
        
        return coordinator
    }
    
    
    private func createWritingContext() -> NSManagedObjectContext? {
        guard let psc = persistentStoreCoordinator else {
            Log("Attempting to create `writingContext` before the `persistentStoreCoordinator` is set up.")
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
            Log("Attempting to create `mainContext` before the persistent store coordinator is setup.")
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


extension CoreDataStack {
    
}




//MARK: - Log -
private var loggingOn: Bool = false
private func Log(message: String, file: String = #file, function: String = #function, line: Int = #line) -> Void {
    guard loggingOn else {
        return
    }
    
    print(">< CoreDataStack ><")
    print("File: \(file)")
    print("Function: \(function), Line: \(line)")
    debugPrint(message)
    print("><><><><><><><><><><")
}





