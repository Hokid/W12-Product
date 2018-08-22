require('../shared/tests/setup.js');

const utils = require('../shared/tests/utils.js');

const PercentMock = artifacts.require('PercentMock');

contract('Percent', async (accounts) => {
    let Percent;

    beforeEach(async () => {
        Percent = await PercentMock.new();
    });

    describe('percent', async () => {
       it('calc percent correctly', async() => {
           const expected = 25;
           const result = await Percent.percent(100, 2500).should.be.fulfilled;

           result.should.bignumber.eq(expected);
       });
    });

    describe('isPercent', async () => {
        it('should return true', async () => {
            const expected = true;
            const result = await Percent.isPercent(2500).should.be.fulfilled;

            result.should.be.eq(expected);
        });

        it('should return false', async () => {
            const expected = false;
            const result = await Percent.isPercent(10001).should.be.fulfilled;

            result.should.be.eq(expected);
        });
    });

    describe('converting', async () => {
        it('to', async () => {
            const expected = 2500;
            const result = await Percent.toPercent(25).should.be.fulfilled;

            result.should.bignumber.eq(expected);
        });

        it('from', async () => {
            const expected = 25;
            const result = await Percent.fromPercent(2500).should.be.fulfilled;

            result.should.bignumber.eq(expected);
        });
    });
});
