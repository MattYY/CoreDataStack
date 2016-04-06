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
    
    
    //Test delete removes only intended files (sqlite)
    func testDeleteSQLiteFiles() {
        let containerURL = createContainerFromName("TestDir")
        
        //create sqlite
        var stack = createStack(containerURL)
        let fileManager = NSFileManager.defaultManager()
        
        let newFilePath = containerURL.relativePath?.stringByAppendingString("/randomFile.test")
        fileManager.createFileAtPath(newFilePath!, contents: nil, attributes: nil)
        
        //delete sqlite
        stack.deleteStore(andRejuvenate: false)
        
        do {
            let urls = try fileManager.contentsOfDirectoryAtURL(
                containerURL, includingPropertiesForKeys: [], options: .SkipsSubdirectoryDescendants)
            
            let sqliteUrls = urls.filter { nil != $0.absoluteString.rangeOfString("\(Constants.ModelName).sqlite") }
            let testFiles = urls.filter { nil != $0.absoluteString.rangeOfString("randomFile.test") }
            
            XCTAssertEqual(sqliteUrls.count, 0)
            XCTAssertEqual(testFiles.count, 1)
            
            //Clean up
            do {
                try fileManager.removeItemAtURL(testFiles[0])
            }
            catch {}
        } catch {}
        
        //clean up
        deleteContainerAtPath(containerURL)
    }
    
    
    func testDeleteRejuvenation() {
        let containerURL = createContainerFromName("TestDir")
        
        //create sqlite
        var stack = createStack(containerURL)
        let fileManager = NSFileManager.defaultManager()
        
        let testSQLFileCount = {
            do {
                let urls = try fileManager.contentsOfDirectoryAtURL(
                    containerURL, includingPropertiesForKeys: [], options: .SkipsSubdirectoryDescendants)
                
                let sqliteUrls = urls.filter { nil != $0.absoluteString.rangeOfString("\(Constants.ModelName).sqlite") }
                XCTAssertEqual(sqliteUrls.count, 3)
            } catch {}
        }
        
        //pre
        testSQLFileCount()

        //delete sqlite
        stack.deleteStore(andRejuvenate: true)
        
        //post
        testSQLFileCount()
        
        //clean up
        deleteContainerAtPath(containerURL)
    }
    
    
    func testMainContextSave() {
        let containerURL = createContainerFromName("TestDir")
        let stack = createStack(containerURL)
        
        guard let context = stack.mainContext else {
            fatalError()
        }
        
        let entity = createTestObj(context)
        entity.testString = "BLAH"
        
        let expection = expectationWithDescription("SaveStore")
        stack.saveToDisk() {
            error in
            expection.fulfill()
        }
        waitForExpectationsWithTimeout(3.0, handler: nil)
        
        let fetchRequest = NSFetchRequest(entityName: Constants.EntityName)
        fetchRequest.fetchLimit = 1
        do {
            let result = try context.executeFetchRequest(fetchRequest).first
            let obj = result as! TestEntity
            XCTAssertEqual(obj.testString, "BLAH")
        }
        catch { }

        //clean up container
        deleteContainerAtPath(containerURL)
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
    
    private func createStack(containerURL: NSURL) -> CoreDataStack {
        let bundle = NSBundle(forClass: StackTests.self)
        let stack = CoreDataStack(
            bundle: bundle,
            modelName: Constants.ModelName,
            containerURL: containerURL,
            inMemoryStore: false,
            logDebugOutput: true)
        
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
