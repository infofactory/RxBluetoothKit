import Foundation
import CoreBluetooth
import RxSwift

class CharacteristicNotificationManager {

    private unowned let peripheral: CBPeripheral
    private let delegateWrapper: CBPeripheralDelegateWrapper
    private var uuidToActiveObservableMap: [CBUUID: [CBUUID: Observable<Characteristic>]] = [:]
    private var uuidToActiveObservablesCountMap: [CBUUID: [CBUUID: Int]] = [:]
    private let lock = NSLock()

    init(peripheral: CBPeripheral, delegateWrapper: CBPeripheralDelegateWrapper) {
        self.peripheral = peripheral
        self.delegateWrapper = delegateWrapper
    }

    func observeValueUpdateAndSetNotification(for characteristic: Characteristic) -> Observable<Characteristic> {
        return .deferred { [weak self] in
            guard let strongSelf = self else { throw BluetoothError.destroyed }
            strongSelf.lock.lock(); defer { strongSelf.lock.unlock()}

            if let activeObservable = strongSelf.uuidToActiveObservableMap[characteristic.service.uuid]?[characteristic.uuid] {
                return activeObservable
            }

            let notificationObserable = strongSelf.createValueUpdateObservable(for: characteristic)
            let observable = notificationObserable
                .do(onSubscribed: { [weak self] in
                    guard let strongSelf = self else { return }
                    strongSelf.lock.lock(); defer { strongSelf.lock.unlock() }
                    let counter = strongSelf.uuidToActiveObservablesCountMap[characteristic.service.uuid]?[characteristic.uuid] ?? 0
                    if strongSelf.uuidToActiveObservableMap[characteristic.service.uuid] == nil {
                        strongSelf.uuidToActiveObservableMap[characteristic.service.uuid] = [:]
                    }
                    strongSelf.uuidToActiveObservablesCountMap[characteristic.service.uuid]?[characteristic.uuid] = counter + 1
                    self?.setNotifyValue(true, for: characteristic)
                }, onDispose: { [weak self] in
                    guard let strongSelf = self else { return }
                    strongSelf.lock.lock(); defer { strongSelf.lock.unlock() }
                    let counter = strongSelf.uuidToActiveObservablesCountMap[characteristic.service.uuid]?[characteristic.uuid] ?? 1
                    if strongSelf.uuidToActiveObservableMap[characteristic.service.uuid] == nil {
                        strongSelf.uuidToActiveObservableMap[characteristic.service.uuid] = [:]
                    }
                    strongSelf.uuidToActiveObservablesCountMap[characteristic.service.uuid]?[characteristic.uuid] = counter - 1

                    if counter <= 1 {
                        strongSelf.uuidToActiveObservableMap[characteristic.service.uuid]?.removeValue(forKey: characteristic.uuid)
                        if strongSelf.uuidToActiveObservableMap[characteristic.service.uuid]?.count ?? 0 > 0 {
                            strongSelf.uuidToActiveObservableMap.removeValue(forKey: characteristic.service.uuid)
                        }
                        strongSelf.setNotifyValue(false, for: characteristic)
                    }
                })
                .share()

            if strongSelf.uuidToActiveObservableMap[characteristic.service.uuid] == nil {
                strongSelf.uuidToActiveObservableMap[characteristic.service.uuid] = [:]
            }
            strongSelf.uuidToActiveObservableMap[characteristic.service.uuid]?[characteristic.uuid] = observable
            
            return observable
        }
    }

    private func createValueUpdateObservable(for characteristic: Characteristic) -> Observable<Characteristic> {
        return delegateWrapper
            .peripheralDidUpdateValueForCharacteristic
            .filter { $0.0 == characteristic.characteristic }
            .map { (_, error) -> Characteristic in
                if let error = error {
                    throw BluetoothError.characteristicReadFailed(characteristic, error)
                }
                return characteristic
            }
    }

    private func setNotifyValue(_ enabled: Bool, for characteristic: Characteristic) {
        guard peripheral.state == .connected else {
            RxBluetoothKitLog.w("\(String(describing: peripheral.logDescription)) is not connected." +
                " Changing notification state for not connected peripheral is not possible.")
            return
        }
        peripheral.setNotifyValue(enabled, for: characteristic.characteristic)
    }
}
