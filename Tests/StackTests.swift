//
//  Tests.swift
//  Tests
//
//  Created by Matthew Yannascoli on 4/5/16.
//  Copyright © 2016 my. All rights reserved.
//

import XCTest
import CoreData
@testable import CoreDataStack

class StackTests: XCTestCase {
    struct Constants {
        static let ModelName = "TestModel"
        static let EntityName = "TestEntity"
    }
    
    //MARK: Delete
    //Test delete removes only intended files (sqlite)

    func testSQLiteFilesAreDeleted() {
        let containerURL = createContainerFromName("TestDir")
        
        //create sqlite
        let stack = try! createStack(containerURL)
        
        let entity = createTestObj(stack.mainContext)
        entity.testString = "BLAH"
        
        let expectation = expectationWithDescription("SaveStore")
        stack.saveToDisk() {
            error in
            XCTAssertNil(error)
            expectation.fulfill()
        }
        
        waitForExpectationsWithTimeout(3.0, handler: nil)
        
        do {
            
            try stack.deleteStore()
            
            //            let urls = try NSFileManager.defaultManager().contentsOfDirectoryAtURL(
            //                containerURL, includingPropertiesForKeys: [], options: .SkipsSubdirectoryDescendants)
            //
            //            let sqliteUrls = urls.filter { nil != $0.absoluteString.rangeOfString("\(Constants.ModelName).sqlite") }
            //            let testFiles = urls.filter { nil != $0.absoluteString.rangeOfString("randomFile.test") }
            //
            //
            //
            //
            //            XCTAssertEqual(sqliteUrls.count, 0)
            //            XCTAssertEqual(testFiles.count, 1)
            //
            
        } catch let e {
        
            XCTFail("Delete failed: \(e)")
        }
        //
        
        //delete sqlite
        

        
        
        
        //clean up
        //deleteContainerAtPath(containerURL)
    }
//
//    
//    //Test sqlite files are rejuvenated
//    func testDeletedFilesAreRejuvenated() {
//        let containerURL = createContainerFromName("TestDir")
//        
//        //create sqlite
//        var stack = createStack(containerURL)
//        let fileManager = NSFileManager.defaultManager()
//        
//        let testSQLFileCount = {
//            do {
//                let urls = try fileManager.contentsOfDirectoryAtURL(
//                    containerURL, includingPropertiesForKeys: [], options: .SkipsSubdirectoryDescendants)
//                
//                let sqliteUrls = urls.filter { nil != $0.absoluteString.rangeOfString("\(Constants.ModelName).sqlite") }
//                XCTAssertEqual(sqliteUrls.count, 3)
//            } catch {}
//        }
//        
//        //pre
//        testSQLFileCount()
//
//        //delete sqlite
//        do {
//            try stack.deleteStore()
//        }
//        catch {}
//        
//        //post
//        testSQLFileCount()
//        
//        //clean up
//        deleteContainerAtPath(containerURL)
//    }
//    
//    
//    func testStackMainContextIsRejuvenated() {
//        let containerURL = createContainerFromName("TestDir")
//        var stack = createStack(containerURL)
//
//        do {
//            try stack.deleteStore()
//            XCTAssertNil(stack.mainContext)
//        }
//        catch {}
//
//        //clean up
//        deleteContainerAtPath(containerURL)
//    }
    
    /*
    func testStackMainContextIsRejuvenated() {
        let containerURL = createContainerFromName("TestDir")
        var stack = createStack(containerURL)
        
        let expectation = expectationWithDescription("DeleteThenSaveStore")
        
        //rejuvenate the stack
        stack.deleteStore(andRejuvenate: true) {
            error in
            
            
            guard let context = stack.mainContext else {
                XCTFail()
                return
            }
            
            expectation.fulfill()
            
            let entity = self.createTestObj(context)
            entity.testString = "BLAH"

            stack.saveToDisk() {
                error in

                let fetchRequest = NSFetchRequest(entityName: Constants.EntityName)
                fetchRequest.fetchLimit = 1
                do {
                    let result = try context.executeFetchRequest(fetchRequest).first
                    let obj = result as! TestEntity
                    XCTAssertEqual(obj.testString, "BLAH")


                }
                catch { }
            }
        }
        
        waitForExpectationsWithTimeout(10.0, handler: nil)
        
        //clean up
        deleteContainerAtPath(containerURL)
    }
    */
 
    
    
    //MARK: Save
    func testDataIsSavedOnTheMainContext() {
        let string: String("s").unicodeScalars
        
        let containerURL = createContainerFromName("TestDir")
        let stack = try! createStack(containerURL)

        let entity = createTestObj(stack.mainContext)
        entity.testString = "BLAH"
        
        let expectation = expectationWithDescription("SaveStore")
        stack.saveToDisk() {
            error in
            expectation.fulfill()
        }
        waitForExpectationsWithTimeout(3.0, handler: nil)
        
        let fetchRequest = NSFetchRequest(entityName: Constants.EntityName)
        fetchRequest.fetchLimit = 1
        do {
            //make sure the fetching context is clean
            stack.mainContext.reset()
            
            let result = try stack.mainContext.executeFetchRequest(fetchRequest).first
            let obj = result as! TestEntity
            XCTAssertEqual(obj.testString, "BLAH")
        }
        catch { }

        //clean up
        deleteContainerAtPath(containerURL)
    }
    
    
    func testDataIsSavedOnAConcurrentContext() {
        let containerURL = createContainerFromName("New4")
        let stack = try! createStack(containerURL)

        guard let context = stack.concurrentContext() else {
            XCTFail()
            return
        }
        
        let expectation = expectationWithDescription("SaveStore")
        context.performBlock {
            for i in 0..<1000 {
                let entity = self.createTestObj(context)
                entity.testString = "string\(i)"
            }
            
            stack.saveToDisk(context) { (error) in
                let fetchRequest = NSFetchRequest(entityName: Constants.EntityName)
                do {
                    //make sure the fetching context is clean
                    stack.mainContext.reset()
                    
                    let result = try stack.mainContext.executeFetchRequest(fetchRequest)
                    let entities = result as? [TestEntity]
                    
                    XCTAssertEqual(entities!.count, 1000)
                    expectation.fulfill()
                }
                catch { }
            }
        }
        
        waitForExpectationsWithTimeout(10.0, handler: nil)
        
        //clean up
        //deleteContainerAtPath(containerURL)
    }
    
    
    
    //MARK: Delete
    func testSavingToADeletedStoreReturnsAnError() {
//        let containerURL = createContainerFromName("TestDir")
//        var stack = createStack(containerURL)
//        
//        guard let context = stack.concurrentContext() else {
//            XCTFail()
//            return
//        }
//        
//        let expectation = expectationWithDescription("DeleteStore")
//        
//        //destroy and rebuild mainContext
//        do {
//            try stack.deleteStore()
//            stack.saveToDisk(context) {
//                error in
//                
//                XCTAssertNotNil(error)
//                expectation.fulfill()
//            }
//        }
//        catch {}
//        
//        waitForExpectationsWithTimeout(10.0, handler: nil)
//        
//        //clean up
//        deleteContainerAtPath(containerURL)
    }

}





//MARK: - Utilities -
extension StackTests {
    private func createContainerFromName(name: String) -> NSURL {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.DocumentDirectory, .UserDomainMask, true)[0]
        let fullPath = documentsPath.stringByAppendingString("/\(name)")
        let url = NSURL(fileURLWithPath: fullPath, isDirectory: true)
        
        //Create the container if necessary
        var error:NSError?
        if !url.checkResourceIsReachableAndReturnError(&error) {
            do {
                try NSFileManager.defaultManager().createDirectoryAtURL(
                    url,
                    withIntermediateDirectories: true,
                    attributes: nil)
            }
            catch {
                fatalError()
            }
        }
        
        print("Container URL: \(url.absoluteString)")
        return url
    }
    
    private func deleteContainerAtPath(path: NSURL) {
        do {
            try NSFileManager.defaultManager().removeItemAtURL(path)
        }
        catch {}
    }
    
    private func createStack(containerURL: NSURL) throws -> CoreDataStack {
        let bundle = NSBundle(forClass: StackTests.self)
        
        let stack = try CoreDataStack(
            bundle: bundle,
            modelName: Constants.ModelName,
            containerURL: containerURL,
            inMemoryStore: false,
            logOutput: true)
        
        return stack
    }
    
    private func createTestObj(context: NSManagedObjectContext) -> TestEntity {
        let entityDescription = NSEntityDescription.entityForName(Constants.EntityName, inManagedObjectContext: context)
        guard let description = entityDescription else {
            fatalError()
        }
        
        let testObj = NSManagedObject(entity: description, insertIntoManagedObjectContext: context) as? TestEntity
        guard let obj = testObj else {
            fatalError()
        }
        
        return obj
    }
}
