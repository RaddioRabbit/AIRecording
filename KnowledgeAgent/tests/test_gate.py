import asyncio

from agent.main import MaintenanceGate


def test_cancelled_reader_waiting_for_writer_does_not_stall_future_traffic():
    async def run():
        gate = MaintenanceGate()
        async with gate.exclusive():
            waiting_reader = asyncio.create_task(_hold_shared(gate))
            await asyncio.sleep(0)
            waiting_reader.cancel()
            await asyncio.gather(waiting_reader, return_exceptions=True)
        async with gate.shared():
            pass

    asyncio.run(run())


def test_cancelled_writer_waiting_for_reader_does_not_block_new_readers():
    async def run():
        gate = MaintenanceGate()
        async with gate.shared():
            waiting_writer = asyncio.create_task(_hold_exclusive(gate))
            await asyncio.sleep(0)
            waiting_writer.cancel()
            await asyncio.gather(waiting_writer, return_exceptions=True)
        async with gate.shared():
            pass

    asyncio.run(run())


async def _hold_shared(gate: MaintenanceGate) -> None:
    async with gate.shared():
        await asyncio.Event().wait()


async def _hold_exclusive(gate: MaintenanceGate) -> None:
    async with gate.exclusive():
        await asyncio.Event().wait()
