//
//  Tests.swift
//  Tests
//
//  Created by Matthew Yannascoli on 4/5/16.
//  Copyright © 2016 Matthew Yannascoli. All rights reserved.
//

import XCTest
import CoreData
@testable import CoreDataStack

//Given
//When
//Then

class StackTests: XCTestCase {
    var stack: CoreDataStack?
    var testEntity: TestEntity?
    var concurrentContext: NSManagedObjectContext?
}


//MARK: - Tests -
extension StackTests {
    
    override func setUp() {
        super.setUp()
        givenAFreshStackWithContainerName("TestDir")
    }
    
    override func tearDown() {
        super.tearDown()
        deleteContainerWithName("TestDir")
    }
    
    
    func testDataIsSavedOnTheMainContext() {
        //given
        givenATestEntityCreatedOnTheMainContext()
        givenATestEntityParamValueOfBLAH()
        
        //when
        whenISaveToDiskWithoutSpecifyingContext()
        
        //then
        thenAFetchOnTheMainContextShouldReturnOneTestEntityWithATestStringEqualToBLAH()
    }
    
    
    func testDataIsNotSavedOnAConcurrentContextIfYouDontPassContextToSaveToDisk() {
        
        //given
        givenAConcurrentContext()
        givenATestEntityCreatedOnAConcurrentContext()
        givenATestEntityParamValueOfBLAH()
        
        //when
        whenISaveToDiskWithoutSpecifyingContext()
        
        //then
        thenAFetchOnTheMainContextShouldReturnZeroItems()
    }
    
    func testDataIsSavedOnAConcurrentContext() {
        
        //given
        givenAConcurrentContext()
        givenATestEntityCreatedOnAConcurrentContext()
        givenATestEntityParamValueOfBLAH()
        
        //when
        whenICallSaveToDiskAndPassConcurrentContextAsAParam()
        
        //then
        thenAFetchOnTheMainContextShouldReturnOneTestEntityWithATestStringEqualToBLAH()
    }
    
    
    func testDeletingAStoreWillCauseAnErrorOnASubsequentSave() {
        //when
        whenIDeleteTheStackStore()
        
        //then
        thenASaveOnMainContextWillReturnAnError()
    }

    func testDeletingTheStoreResetsTheMainContext() {
        //given
        givenAConcurrentContext()
        givenATestEntityCreatedOnTheMainContext()
        
        //when
        whenIDeleteTheStackStore()
        
        //then
        thenAFetchOnTheMainContextShouldReturnZeroItems()
    }
}



//MARK: - Given -
extension StackTests {
    
    func givenAFreshStackWithContainerName(containerName: String) {
        let containerURL = createContainerFromName(containerName)
        let bundle = NSBundle(forClass: StackTests.self)
        
        let s = try! CoreDataStack(
            bundle: bundle,
            directoryURL: containerURL,
            modelName: "TestModel",
            inMemoryStore: false,
            logOutput: true)
        
        stack = s
    }
    
    func givenAConcurrentContext() {
        concurrentContext =  stack!.concurrentContext()
    }
    
    func givenATestEntityCreatedOnTheMainContext() {
        let description = NSEntityDescription.entityForName(
            "TestEntity", inManagedObjectContext: stack!.mainContext)!
        
        testEntity = NSManagedObject(
            entity: description, insertIntoManagedObjectContext: stack!.mainContext) as? TestEntity
    }
    
    func givenATestEntityCreatedOnAConcurrentContext() {
        let description = NSEntityDescription.entityForName(
            "TestEntity", inManagedObjectContext: concurrentContext!)!
        
        testEntity = NSManagedObject(entity: description, insertIntoManagedObjectContext: concurrentContext!) as? TestEntity
    }
    
    func givenATestEntityParamValueOfBLAH() {
        testEntity?.testString = "BLAH"
    }
}



//MARK: - When -
extension StackTests {
    
    func whenISaveToDiskWithoutSpecifyingContext() {
        let expectation = expectationWithDescription("SaveStore")
        stack!.saveToDisk() {
            error in
            expectation.fulfill()
        }
        waitForExpectationsWithTimeout(3.0, handler: nil)
    }
    
    func whenICallSaveToDiskAndPassConcurrentContextAsAParam() {
        let expectation = expectationWithDescription("SaveStore")
        stack!.saveToDisk(concurrentContext!) {
            error in
            expectation.fulfill()
        }
        waitForExpectationsWithTimeout(3.0, handler: nil)
    }
    
    func whenIDeleteTheStackStore() {
        try! stack!.deleteStore()
    }
    
}


//MARK: - Then -
extension StackTests {
    
    func thenAFetchOnTheMainContextShouldReturnZeroItems() {
        let expectation = expectationWithDescription("Fetch")
        stack!.mainContext.performBlock {
            expectation.fulfill()
        }
        waitForExpectationsWithTimeout(3.0, handler: nil)
    }
    
    func thenAFetchOnTheMainContextShouldReturnOneTestEntityWithATestStringEqualToBLAH() {
        let expectation = expectationWithDescription("Fetch")
        stack!.mainContext.performBlock {
            let fetchRequest = NSFetchRequest(entityName: "TestEntity")
            do {
                let results = try self.stack!.mainContext.executeFetchRequest(fetchRequest)
                XCTAssertEqual(results.count, 1)
                
                let obj = results.first as! TestEntity
                XCTAssertEqual(obj.testString, "BLAH")
                expectation.fulfill()
            }
            catch {}
        }
        waitForExpectationsWithTimeout(3.0, handler: nil)
    }
    
    func thenASaveOnMainContextWillReturnAnError() {
        
        let expectation = expectationWithDescription("Save")
        stack!.saveToDisk() {
            error in
            
            XCTAssertNotNil(error)
            expectation.fulfill()
        }
        
        waitForExpectationsWithTimeout(3.0, handler: nil)
    }
}



//MARK: - Utilities -
extension StackTests {
    private func urlWithName(name: String) -> NSURL {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.DocumentDirectory, .UserDomainMask, true)[0]
        let fullPath = documentsPath.stringByAppendingString("/\(name)")
        return NSURL(fileURLWithPath: fullPath, isDirectory: true)
    }
    
    private func createContainerFromName(name: String) -> NSURL {
        let url = urlWithName(name)
        
        //Create the container if necessary
        var error:NSError?
        if !url.checkResourceIsReachableAndReturnError(&error) {
            try! NSFileManager.defaultManager().createDirectoryAtURL(
                    url, withIntermediateDirectories: true, attributes: nil)
        }
        
        print("Container URL: \(url.absoluteString)")
        return url
    }
    
    private func deleteContainerWithName(name: String) {
        let url = urlWithName(name)
        try! NSFileManager.defaultManager().removeItemAtURL(url)
    }
}
